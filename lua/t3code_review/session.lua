local Path = require 't3code_review.path'
local M = {}

local sessions, anchors = {}, {}
local history = {}
local storage = vim.fn.stdpath 'state' .. '/t3/reviews'
local ns = vim.api.nvim_create_namespace 't3.review.locations'
local counter = 0
local persist_positions

local function storage_file(root)
  return storage .. '/' .. vim.fn.sha256(root) .. '.json'
end

function M.setup(opts)
  if opts and opts.storage_dir then
    storage = opts.storage_dir
  end
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = vim.api.nvim_create_augroup('T3ReviewPositions', { clear = true }),
    callback = function(event)
      persist_positions(event.buf)
    end,
  })
end

function M.get(root)
  root = Path.canonical(root or Path.root())
  if not sessions[root] then
    local file = storage_file(root)
    local session = { root = root, items = {} }
    if vim.uv.fs_stat(file) then
      session = vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
    end

    assert(session.root == root and type(session.items) == 'table', 'Invalid code review: ' .. file)
    sessions[root], anchors[root], history[root] = session, {}, { undo = {}, redo = {} }
  end

  return vim.deepcopy(sessions[root])
end

local function save(session)
  vim.fn.mkdir(storage, 'p', 448)
  local file = storage_file(session.root)
  local temp = file .. '.' .. vim.uv.hrtime()
  local text = vim.json.encode(session)
  local fd = assert(vim.uv.fs_open(temp, 'wx', 384))

  local written, err = vim.uv.fs_write(fd, text)
  vim.uv.fs_close(fd)
  if written ~= #text then
    vim.uv.fs_unlink(temp)
    error(err or 'Could not save code review')
  end

  local ok, rename_err = vim.uv.fs_rename(temp, file)
  if not ok then
    vim.uv.fs_unlink(temp)
    error(rename_err)
  end

  sessions[session.root] = session
  vim.api.nvim_exec_autocmds('User', { pattern = 'T3ReviewChanged', data = { root = session.root } })
end

function M.items(root)
  return M.get(root).items
end

function M.set_target(root, target)
  local session = M.get(root)
  session.target = target
  save(session)
end

local function attach(root, item, buf)
  if not buf or buf < 1 or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end

  local count = vim.api.nvim_buf_line_count(buf)
  anchors[root][item.id] = {
    buf = buf,
    first = vim.api.nvim_buf_set_extmark(buf, ns, math.min(item.reference.first, count) - 1, 0, {}),
    last = vim.api.nvim_buf_set_extmark(buf, ns, math.min(item.reference.last, count) - 1, 0, {}),
  }
end

local function anchor_position(anchor)
  if anchor and vim.api.nvim_buf_is_loaded(anchor.buf) then
    local first = vim.api.nvim_buf_get_extmark_by_id(anchor.buf, ns, anchor.first, {})
    local last = vim.api.nvim_buf_get_extmark_by_id(anchor.buf, ns, anchor.last, {})
    if #first > 0 and #last > 0 then
      return first[1] + 1, math.max(first[1], last[1]) + 1
    end
  end
end

persist_positions = function(buf)
  local path = Path.canonical(vim.api.nvim_buf_get_name(buf))
  local function update(items, root)
    local changed = false
    for _, item in ipairs(items) do
      local anchor = anchors[root][item.id]
      if anchor and anchor.buf == buf and Path.canonical(item.reference.path) == path then
        local first, last = anchor_position(anchor)
        if first and (item.reference.first ~= first or item.reference.last ~= last) then
          item.reference.first, item.reference.last = first, last
          changed = true
        end
      end
    end
    return changed
  end

  for root in pairs(sessions) do
    local ok, err = pcall(function()
      local session = M.get(root)
      if update(session.items, root) then
        save(session)
      end
      -- Undo must not restore line numbers from before the source file was saved.
      for _, stack in pairs(history[root]) do
        for _, change in ipairs(stack) do
          update(change.before, root)
          update(change.after, root)
        end
      end
    end)
    if not ok then
      vim.notify(
        'Could not save review positions: ' .. tostring(err),
        vim.log.levels.ERROR,
        { title = 'nvim-t3code-review' }
      )
    end
  end
end

local function prune_anchors(root)
  local retained = {}
  for _, item in ipairs(sessions[root].items) do
    retained[item.id] = true
  end
  for _, stack in pairs(history[root]) do
    for _, change in ipairs(stack) do
      for _, items in ipairs { change.before, change.after } do
        for _, item in ipairs(items) do
          retained[item.id] = true
        end
      end
    end
  end
  for id, anchor in pairs(anchors[root]) do
    if not retained[id] then
      if vim.api.nvim_buf_is_valid(anchor.buf) then
        vim.api.nvim_buf_del_extmark(anchor.buf, ns, anchor.first)
        vim.api.nvim_buf_del_extmark(anchor.buf, ns, anchor.last)
      end
      anchors[root][id] = nil
    end
  end
end

local function record(session, before, count)
  local changes = history[session.root]
  changes.undo[#changes.undo + 1] = { before = before, after = vim.deepcopy(session.items), count = count }
  changes.redo = {}
  prune_anchors(session.root)
end

function M.add(reference, comment)
  assert(comment:match '%S', 'Add a review comment first')
  local session = M.get(reference.root)
  local before = vim.deepcopy(session.items)
  counter = counter + 1
  local item = {
    id = tostring(vim.uv.hrtime()) .. ':' .. counter,
    comment = comment,
    reference = {
      path = reference.path,
      root = reference.root,
      first = reference.first,
      last = reference.last,
      whole_file = reference.whole_file or nil,
    },
  }

  session.items[#session.items + 1] = item
  save(session)
  record(session, before, 1)
  attach(session.root, item, reference.bufnr)
  return item.id
end

function M.edit(root, id, comment)
  assert(comment:match '%S', 'Add a review comment first')
  local session = M.get(root)
  local before = vim.deepcopy(session.items)

  for _, item in ipairs(session.items) do
    if item.id == id then
      if item.comment == comment then
        return
      end
      item.comment = comment
      save(session)
      record(session, before, 1)
      return
    end
  end

  error 'Review comment no longer exists'
end

local function clear(root, submitted, remember)
  local session = M.get(root)
  local sent, keep, removed = {}, {}, {}
  for _, item in ipairs(submitted or {}) do
    sent[item.id] = item
  end

  for _, item in ipairs(session.items) do
    if not submitted or vim.deep_equal(sent[item.id], item) then
      removed[#removed + 1] = item
    else
      keep[#keep + 1] = item
    end
  end

  local before = session.items
  if #removed > 0 then
    session.items = keep
    save(session)
  end
  if not remember then
    history[session.root] = { undo = {}, redo = {} }
  elseif #removed > 0 then
    record(session, before, #removed)
  end
  prune_anchors(session.root)

  return #removed
end

function M.remove(root, id)
  for _, item in ipairs(M.items(root)) do
    if item.id == id then
      return clear(root, { item }, true)
    end
  end
end

-- A send clears only unchanged submitted entries and cannot be undone.
function M.clear(root, submitted)
  return clear(root, submitted, submitted == nil)
end

local function restore(root, direction, opposite, state)
  local session = M.get(root)
  local changes = history[session.root]
  local change = changes[direction][#changes[direction]]
  if not change then
    return 0
  end
  session.items = vim.deepcopy(change[state])
  save(session)
  table.remove(changes[direction])
  changes[opposite][#changes[opposite] + 1] = change
  return change.count
end

function M.undo(root)
  return restore(root, 'undo', 'redo', 'before')
end

function M.redo(root)
  return restore(root, 'redo', 'undo', 'after')
end

function M.location(root, id)
  local session = M.get(root)

  for _, item in ipairs(session.items) do
    if item.id == id then
      local reference = item.reference
      local anchor = anchors[session.root][id]
      if not anchor then
        attach(session.root, item, vim.fn.bufnr(reference.path))
        anchor = anchors[session.root][id]
      end

      local first, last = anchor_position(anchor)
      first, last = first or reference.first, last or reference.last

      return {
        path = reference.path,
        buf = anchor and anchor.buf,
        pos = { first, 0 },
        end_pos = { math.max(first, last), 0 },
      }
    end
  end
end

function M.format_reference(reference, comment)
  local path = Path.canonical(reference.path)
  local root = Path.canonical(reference.root or Path.root(path))
  if path:sub(1, #root + 1) == root .. '/' then
    path = path:sub(#root + 2)
  end

  local destination = path:gsub('[%s%%#?()]', function(char)
    return string.format('%%%02X', string.byte(char))
  end)
  if not reference.whole_file then
    destination = destination .. ':' .. reference.first
    if reference.last ~= reference.first then
      destination = destination .. '-' .. reference.last
    end
  end

  return '[' .. vim.fs.basename(path) .. '](' .. destination .. ')\n' .. comment
end

function M.format(root)
  local session = M.get(root)
  assert(#session.items > 0, 'The code review is empty')

  local files, order = {}, {}

  for _, item in ipairs(session.items) do
    local location = M.location(session.root, item.id)
    local path = Path.canonical(item.reference.path)
    if not files[path] then
      files[path] = {}
      order[#order + 1] = path
    end
    local reference = {
      path = path,
      root = session.root,
      first = location.pos[1],
      last = location.end_pos[1],
      whole_file = item.reference.whole_file,
    }

    files[path][#files[path] + 1] = M.format_reference(reference, item.comment)
  end

  local parts = {}
  for _, path in ipairs(order) do
    parts[#parts + 1] = table.concat(files[path], '\n\n')
  end

  return table.concat(parts, '\n\n---\n')
end

return M
