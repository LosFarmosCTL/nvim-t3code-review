local Path = require 't3code_review.path'
local M = {}

local sessions, anchors = {}, {}
local storage = vim.fn.stdpath 'state' .. '/t3/reviews'
local ns = vim.api.nvim_create_namespace 't3.review.locations'
local counter = 0

local function storage_file(root)
  return storage .. '/' .. vim.fn.sha256(root) .. '.json'
end

function M.setup(opts)
  if opts and opts.storage_dir then
    storage = opts.storage_dir
  end
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
    sessions[root], anchors[root] = session, {}
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

function M.add(reference, comment)
  assert(comment:match '%S', 'Add a review comment first')
  local session = M.get(reference.root)
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
  attach(session.root, item, reference.bufnr)
  return item.id
end

function M.edit(root, id, comment)
  assert(comment:match '%S', 'Add a review comment first')
  local session = M.get(root)

  for _, item in ipairs(session.items) do
    if item.id == id then
      item.comment = comment
      save(session)
      return
    end
  end

  error 'Review comment no longer exists'
end

function M.remove(root, id)
  for _, item in ipairs(M.items(root)) do
    if item.id == id then
      return M.clear(root, { item })
    end
  end
end

-- A send clears only the submitted entries that have not been edited in the meantime.
function M.clear(root, submitted)
  local session = M.get(root)
  local sent, keep, removed = {}, {}, {}
  for _, item in ipairs(submitted or {}) do
    sent[item.id] = item
  end

  for _, item in ipairs(session.items) do
    if not submitted or vim.deep_equal(sent[item.id], item) then
      removed[#removed + 1] = item.id
    else
      keep[#keep + 1] = item
    end
  end

  session.items = keep
  save(session)

  for _, id in ipairs(removed) do
    local anchor = anchors[session.root][id]
    if anchor and vim.api.nvim_buf_is_valid(anchor.buf) then
      vim.api.nvim_buf_del_extmark(anchor.buf, ns, anchor.first)
      vim.api.nvim_buf_del_extmark(anchor.buf, ns, anchor.last)
    end
    anchors[session.root][id] = nil
  end

  return #removed
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

      local first, last = reference.first, reference.last
      if anchor and vim.api.nvim_buf_is_loaded(anchor.buf) then
        local start = vim.api.nvim_buf_get_extmark_by_id(anchor.buf, ns, anchor.first, {})
        local finish = vim.api.nvim_buf_get_extmark_by_id(anchor.buf, ns, anchor.last, {})
        if #start > 0 and #finish > 0 then
          first, last = start[1] + 1, finish[1] + 1
        end
      end

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
