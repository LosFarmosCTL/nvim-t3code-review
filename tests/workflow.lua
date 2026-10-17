vim.opt.runtimepath:append(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath 'data' .. '/lazy/trouble.nvim')
vim.o.columns, vim.o.lines = 140, 45

local t3, connection, trouble = require 't3code_review', require 't3code_review.connection', require 'trouble'

local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. '/checkout/.git', 'p')
local root = vim.uv.fs_realpath(temp .. '/checkout')

local target = { environment_id = 'env', project_id = 'project', thread_id = 'architecture', name = 'Architecture' }
local choose, failure, handed_off, delivery, send_params = nil, nil, nil, nil, nil
local can_operate, authorization = true, nil
local creation_ceiling = 'full-access'

connection.request = function(operation, params, done)
  if failure then
    done { message = failure }
    return
  end

  local result
  if operation == 'projects' then
    result = { environmentId = 'env', projects = { { id = 'project', title = 'Project', score = 10000 } } }
  elseif operation == 'threads' then
    result = {
      threads = { vim.tbl_extend('force', target, { status = 'idle', same_checkout = true, branch = vim.NIL }) },
      canCreateThreads = true,
    }
  elseif operation == 'validate' then
    result = { target = vim.deepcopy(params.target), canCreateThreads = can_operate, runtimeMode = 'full-access' }
  elseif operation == 'send' then
    send_params, delivery = params, done
    return
  elseif operation == 'connect' then
    authorization, can_operate = params, true
    result = { label = 'Test T3', canCreateThreads = true }
  elseif operation == 'models' then
    result = { runtimeMode = creation_ceiling }
  elseif operation == 'create' then
    result = { target = vim.tbl_extend('force', target, { thread_id = 'new', name = 'New review' }) }
  else
    error('Unexpected bridge operation: ' .. operation)
  end

  done(nil, result)
end

vim.ui.select = function(items, opts, done)
  if opts.format_item then
    for _, item in ipairs(items) do
      opts.format_item(item)
    end
  end

  done(choose and choose(items) or items[1])
end

vim.ui.input = function(_, done)
  done 'New review'
end

trouble.setup {}
t3.setup { review = { storage_dir = temp .. '/state' } }

vim.system = function(command, _, done)
  handed_off = command[#command]
  if command[1] == 'open' then
    assert(command[#command - 1] == handed_off:match '^[^?]+')
  end

  done { code = 0 }
end

local source, window = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_name(source, root .. '/service.lua')
vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'header', string.rep('source_code_marker', 10000), 'return value' })

local function wait(fn)
  assert(vim.wait(3000, fn, 10), 'Workflow timed out')
end

local function save_comment(text, complete)
  wait(function()
    return vim.bo.filetype == 'markdown'
  end)

  local popup = vim.api.nvim_get_current_buf()
  local config = vim.api.nvim_win_get_config(0)
  assert(config.title[1][1]:match 'review comment')
  assert(config.footer[1][1]:find('switch thread', 1, true))

  vim.api.nvim_buf_set_lines(popup, 0, -1, false, { text })

  for _, key in ipairs(vim.api.nvim_buf_get_keymap(popup, 'n')) do
    if key.lhs == '<C-S>' then
      key.callback()
      if complete then
        complete()
      end
      wait(function()
        return vim.api.nvim_get_current_buf() ~= popup
      end)
      return
    end
  end

  error 'Comment save key missing'
end

-- Select lines, comment, resume, navigate, edit, then stage one reference-only review.
vim.api.nvim_set_current_win(window)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd.normal { args = { 'Vj' }, bang = true }
t3.add_comment { visual = true }
wait(function()
  return vim.bo.filetype == 'markdown'
end)

local popup = vim.api.nvim_get_current_buf()
assert(not trouble.is_open 't3_review')
vim.api.nvim_buf_set_lines(popup, 0, -1, false, { 'Keep this comment while switching' })

for _, key in ipairs(vim.api.nvim_buf_get_keymap(popup, 'n')) do
  if key.lhs == '<C-T>' then
    key.callback()
  end
end

assert(
  vim.api.nvim_get_current_buf() == popup
    and vim.api.nvim_buf_get_lines(popup, 0, 1, false)[1] == 'Keep this comment while switching'
)

save_comment 'Move retry ownership'
local ready = false
require('trouble.view').get({ mode = 't3_review' })[1].view:wait(function()
  ready = true
end)
wait(function()
  return ready
end)
wait(function()
  return #trouble.get_items 't3_review' == 1
end)

vim.cmd 'T3ShowReview'
t3.show_review()
assert(#require('trouble.view').get { mode = 't3_review' } == 1)

local item = t3.session.items(root)[1]
assert(item.reference.first == 2 and item.reference.last == 3 and item.reference.text == nil)

vim.api.nvim_buf_set_lines(source, 0, 0, false, { 'new header' })
assert(t3.session.location(root, item.id).pos[1] == 3)

t3.edit_comment(item.id, { root = root })
save_comment 'Keep retry ownership in the service'

vim.cmd 'T3DraftReview'

local prompt = handed_off:match('prompt=(.*)'):gsub('%%(%x%x)', function(hex)
  return string.char(tonumber(hex, 16))
end)

assert(prompt == '[service.lua](service.lua:3-4)\nKeep retry ownership in the service')
assert(not prompt:find('source_code_marker', 1, true))
assert(#prompt < 500 and #t3.session.items(root) == 1)

local saved = dofile 'lua/t3code_review/session.lua'
saved.setup { storage_dir = temp .. '/state' }
assert(saved.items(root)[1].comment == 'Keep retry ownership in the service')
t3.session.setup { storage_dir = temp .. '/state' }

-- Hovering an unloaded file previews it temporarily and restores the main buffer.
local preview_path = root .. '/other.lua'
vim.fn.writefile({ 'preview this file', 'second line' }, preview_path)
local preview_id = t3.session.add({ path = preview_path, root = root, first = 2, last = 2 }, 'Another concern')
wait(function()
  return #trouble.get_items 't3_review' == 2
end)

local view = require('trouble.view').get({ mode = 't3_review' })[1].view
view.win:focus()

local preview_row
wait(function()
  for row = 1, vim.api.nvim_buf_line_count(view.win.buf) do
    local selected = view:at({ row, 0 }).item
    if selected and selected.filename == preview_path then
      preview_row = row
      return true
    end
  end
end)

vim.api.nvim_win_set_cursor(view.win.win, { preview_row, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = view.win.buf })

local preview = require 'trouble.view.preview'
wait(function()
  return preview.is_open() and preview.item().filename == preview_path
end)

-- Rendering the review list must not trigger a refresh of that same list.
local tick = vim.api.nvim_buf_get_changedtick(view.win.buf)
vim.api.nvim_exec_autocmds('TextChanged', { buffer = view.win.buf })
vim.wait(150, function()
  return false
end)

assert(vim.api.nvim_buf_get_changedtick(view.win.buf) == tick)

local preview_buf = preview.preview.buf
assert(not vim.bo[preview_buf].buflisted and vim.api.nvim_buf_get_lines(preview_buf, 1, 2, false)[1] == 'second line')

vim.api.nvim_set_current_win(window)
wait(function()
  return not preview.is_open()
end)

assert(vim.api.nvim_win_get_buf(window) == source)

-- Trouble's normal Enter closes an existing preview and leaves other modes usable.
local cursor, events = vim.o.guicursor, vim.o.eventignore
view.win:focus()

vim.api.nvim_win_set_cursor(view.win.win, { preview_row, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', { buffer = view.win.buf })
wait(function()
  return preview.is_open()
end)

for _, key in ipairs(vim.api.nvim_buf_get_keymap(view.win.buf, 'n')) do
  if key.lhs == '<CR>' then
    key.callback()
  end
end
vim.wait(200, function()
  return false
end)

assert(vim.api.nvim_get_current_win() == window and not preview.is_open())
assert(vim.o.guicursor == cursor and vim.o.eventignore == events)

vim.fn.setqflist { { filename = preview_path, lnum = 1, text = 'Other Trouble view' } }
local quickfix = trouble.open { mode = 'qflist', focus = true }
wait(function()
  return quickfix:is_open() and #trouble.get_items 'qflist' == 1
end)

quickfix:close()

vim.api.nvim_set_current_win(window)
vim.api.nvim_win_set_buf(window, source)
t3.session.remove(root, preview_id)

handed_off = nil
t3.draft_comment { first = 2, last = 2 }
save_comment 'Immediate feedback'
assert(handed_off and #t3.session.items(root) == 1)

-- Direct comments preserve the collected review and stay editable after failed delivery.
vim.cmd '2T3SendComment'
local direct_popup = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(direct_popup, 0, -1, false, { 'Immediate send' })
local submit
for _, key in ipairs(vim.api.nvim_buf_get_keymap(direct_popup, 'n')) do
  if key.lhs == '<C-S>' then
    submit = key.callback
  end
end
assert(submit)
submit()
local direct_request_id, pending = send_params.request_id, delivery
assert(send_params.text == '[service.lua](service.lua:2)\nImmediate send')
submit()
assert(delivery == pending)
delivery { message = 'Comment delivery unavailable' }
assert(vim.api.nvim_get_current_buf() == direct_popup)
assert(vim.api.nvim_buf_get_lines(direct_popup, 0, -1, false)[1] == 'Immediate send')
save_comment('Immediate send', function()
  assert(send_params.request_id == direct_request_id)
  delivery(nil, { delivery = 'queued' })
end)
assert(#t3.session.items(root) == 1 and t3.session.items(root)[1].id == item.id)

-- Separate popups can send identical feedback as separate messages.
local completed
t3.send_comment { first = 2, last = 2, comment = 'Immediate send', done = function(err, receipt)
  assert(not err)
  completed = receipt
end }
save_comment('Immediate send', function()
  assert(send_params.request_id ~= direct_request_id)
  delivery(nil, { delivery = 'started' })
end)
assert(completed.delivery == 'started' and #t3.session.items(root) == 1)

-- Canceling authorization keeps the popup and does not dispatch a message.
can_operate = false
choose = function(items)
  return items[2]
end
t3.send_comment { first = 2, last = 2 }
local canceled_popup, previous_delivery = vim.api.nvim_get_current_buf(), delivery
vim.api.nvim_buf_set_lines(canceled_popup, 0, -1, false, { 'Send after authorization' })
for _, key in ipairs(vim.api.nvim_buf_get_keymap(canceled_popup, 'n')) do
  if key.lhs == '<C-S>' then
    key.callback()
  end
end
assert(vim.api.nvim_get_current_buf() == canceled_popup and delivery == previous_delivery)
choose, can_operate = nil, true
save_comment('Send after authorization', function()
  delivery(nil, { delivery = 'queued' })
end)
assert(#t3.session.items(root) == 1)

-- A failed handoff keeps the review; choosing a new thread changes its recipient.
handed_off, failure = nil, 'Thread unavailable'
t3.draft_review { root = root }
assert(handed_off == nil and #t3.session.items(root) == 1)

failure = nil

choose = function(items)
  for _, row in ipairs(items) do
    if row.action == 'new' then
      return row
    end
  end

  return items[1]
end

-- Use the project's configured model for this workflow check.
local request = connection.request

connection.request = function(operation, params, done)
  if operation == 'projects' then
    done(nil, {
      environmentId = 'env',
      projects = { { id = 'project', title = 'Project', score = 10000, defaultModelSelection = { model = 'model' } } },
    })
  else
    request(operation, params, done)
  end
end

authorization = nil
vim.cmd 'T3SelectThread'
assert(t3.session.get(root).target.thread_id == 'new')
assert(authorization == nil)

-- A supervised connection must authorize full-access thread creation.
creation_ceiling = 'approval-required'
vim.cmd 'T3SelectThread'
assert(authorization.access == 'operate' and authorization.runtime_mode == 'full-access')
creation_ceiling = 'full-access'

-- Sending retains comments on failure, deduplicates retries, and clears only unchanged submissions.
choose, can_operate = nil, false

t3.send_review { root = root }
assert(authorization.access == 'operate' and authorization.runtime_mode == 'full-access')

local request_id = send_params.request_id
assert(send_params.text == prompt)

delivery { message = 'Delivery unavailable' }
assert(#t3.session.items(root) == 1)

t3.send_review { root = root }
assert(send_params.request_id == request_id)
t3.session.edit(root, item.id, 'Edited while sending')
delivery(nil, { delivery = 'queued' })
assert(#t3.session.items(root) == 1)

t3.send_review { root = root }
local new_id = t3.session.add({ path = preview_path, root = root, first = 1, last = 1 }, 'Added while sending')
delivery(nil, { delivery = 'started' })
assert(#t3.session.items(root) == 1 and t3.session.items(root)[1].id == new_id)
assert(t3.session.undo(root) == 0)

t3.clear_review { root = root }
assert(#t3.session.items(root) == 0)
assert(t3.session.get(root).target.thread_id == 'new')

-- Group comments by file, with compact links for lines, ranges, and whole files.
t3.session.add({ path = root .. '/service.lua', root = root, first = 2, last = 2 }, 'First comment')
t3.session.add({ path = preview_path, root = root, first = 1, last = 2, whole_file = true }, 'Whole file comment')
t3.session.add({ path = root .. '/service.lua', root = root, first = 3, last = 4 }, 'Another comment')
assert(
  t3.session.format(root)
    == '[service.lua](service.lua:2)\nFirst comment\n\n'
      .. '[service.lua](service.lua:3-4)\nAnother comment\n\n---\n'
      .. '[other.lua](other.lua)\nWhole file comment'
)

-- Additions and edits share the review history; code-buffer undo stays separate.
local history_root = temp .. '/history'
vim.fn.mkdir(history_root .. '/.git', 'p')
local history_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(history_buf, history_root .. '/file.lua')
vim.api.nvim_buf_set_lines(history_buf, 0, -1, false, { 'first', 'second', 'third' })
local reference = { root = history_root, path = history_root .. '/file.lua', first = 2, last = 2, bufnr = history_buf }
assert(t3.session.undo(history_root) == 0 and t3.session.redo(history_root) == 0)
local first = t3.session.add(reference, 'First')
assert(t3.session.undo(history_root) == 1 and #t3.session.items(history_root) == 0)
vim.api.nvim_buf_set_lines(history_buf, 0, 0, false, { 'inserted while undone' })
assert(t3.session.redo(history_root) == 1 and t3.session.items(history_root)[1].id == first)
assert(t3.session.location(history_root, first).pos[1] == 3)
local second = t3.session.add(reference, 'Second')
t3.session.set_target(history_root, target)
t3.session.edit(history_root, second, 'Second edited')
t3.session.edit(history_root, second, 'Second edited')
assert(t3.session.undo(history_root) == 1 and t3.session.items(history_root)[2].comment == 'Second')
assert(t3.session.redo(history_root) == 1 and t3.session.items(history_root)[2].comment == 'Second edited')

-- Deleted comments retain their order and keep following source edits.
t3.session.remove(history_root, first)
vim.api.nvim_buf_set_lines(history_buf, 0, 0, false, { 'inserted while deleted' })
local actions = require('trouble.sources.t3_review').config.modes.t3_review.keys
local history_view = { opts = { params = { root = history_root } } }
actions.u.action(history_view)
assert(t3.session.items(history_root)[1].id == first and t3.session.items(history_root)[2].id == second)
assert(t3.session.location(history_root, first).pos[1] == 4)
actions['<C-r>'].action(history_view)
assert(#t3.session.items(history_root) == 1 and t3.session.items(history_root)[1].id == second)
actions.u.action(history_view)

-- Clear and add are separate steps that undo and redo in chronological order.
assert(t3.session.clear(history_root) == 2)
assert(t3.session.clear(history_root) == 0)
assert(t3.session.undo(history_root) == 2)
assert(t3.session.get(history_root).target.thread_id == target.thread_id)
assert(t3.session.redo(history_root) == 2 and #t3.session.items(history_root) == 0)
local third = t3.session.add(reference, 'Third')
assert(t3.session.undo(history_root) == 1 and #t3.session.items(history_root) == 0)
assert(t3.session.undo(history_root) == 2)
local restored = t3.session.items(history_root)
assert(restored[1].id == first and restored[2].id == second)
assert(t3.session.redo(history_root) == 2 and #t3.session.items(history_root) == 0)
assert(t3.session.redo(history_root) == 1 and t3.session.items(history_root)[1].id == third)

-- Adding or editing after undo replaces the redo branch; histories are per checkout.
t3.session.undo(history_root)
local fourth = t3.session.add(reference, 'Fourth')
assert(t3.session.redo(history_root) == 0)
t3.session.edit(history_root, fourth, 'Fourth edited')
t3.session.undo(history_root)
t3.session.edit(history_root, fourth, 'Fourth replacement')
assert(t3.session.redo(history_root) == 0)
assert(t3.session.undo(history_root) == 1 and t3.session.items(history_root)[1].comment == 'Fourth')
assert(t3.session.redo(history_root) == 1 and t3.session.items(history_root)[1].comment == 'Fourth replacement')
assert(t3.session.undo(root) == 1)
assert(#t3.session.items(history_root) == 1)
assert(t3.session.redo(root) == 1)

-- Restored state is persisted, but undo history is session-local.
local reloaded = dofile 'lua/t3code_review/session.lua'
reloaded.setup { storage_dir = temp .. '/state' }
assert(reloaded.items(history_root)[1].comment == 'Fourth replacement')
assert(reloaded.undo(history_root) == 0)
t3.session.setup { storage_dir = temp .. '/state' }

-- Confirmed delivery discards both stacks, even when every comment changed during delivery.
local submitted = t3.session.items(history_root)
t3.session.edit(history_root, fourth, 'Changed during delivery')
t3.session.clear(history_root, submitted)
assert(t3.session.undo(history_root) == 0 and t3.session.redo(history_root) == 0)
assert(#t3.session.items(history_root) == 1 and t3.session.items(history_root)[1].id == fourth)
vim.api.nvim_buf_delete(history_buf, { force = true })

-- Saving source edits persists live ranges, including ranges retained by undo history.
local position_root = temp .. '/positions'
vim.fn.mkdir(position_root .. '/.git', 'p')
local position_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(position_buf, position_root .. '/file.lua')
vim.api.nvim_buf_set_lines(position_buf, 0, -1, false, { 'header', 'first', 'second', 'footer' })
local position_id = t3.session.add({
  root = position_root,
  path = position_root .. '/file.lua',
  first = 2,
  last = 3,
  bufnr = position_buf,
}, 'Keep this range')
vim.api.nvim_buf_set_lines(position_buf, 0, 0, false, { 'inserted one', 'inserted two' })
assert(t3.session.location(position_root, position_id).pos[1] == 4)
assert(t3.session.items(position_root)[1].reference.first == 2)
vim.api.nvim_buf_call(position_buf, function()
  vim.cmd 'silent write'
end)

local restarted = dofile 'lua/t3code_review/session.lua'
restarted.setup { storage_dir = temp .. '/state' }
local persisted = restarted.items(position_root)[1]
assert(persisted.reference.first == 4 and persisted.reference.last == 5)
assert(restarted.location(position_root, position_id).pos[1] == 4)
t3.session.setup { storage_dir = temp .. '/state' }

-- Position updates do not add undo steps or overwrite edits to comment text.
t3.session.edit(position_root, position_id, 'Updated feedback')
vim.api.nvim_buf_set_lines(position_buf, 0, 0, false, { 'another insertion' })
vim.api.nvim_buf_call(position_buf, function()
  vim.cmd 'silent write'
end)
assert(t3.session.undo(position_root) == 1)
persisted = t3.session.items(position_root)[1]
assert(persisted.comment == 'Keep this range' and persisted.reference.first == 5 and persisted.reference.last == 6)

t3.session.remove(position_root, position_id)
vim.api.nvim_buf_set_lines(position_buf, 0, 0, false, { 'inserted while deleted' })
vim.api.nvim_buf_call(position_buf, function()
  vim.cmd 'silent write'
end)
assert(t3.session.undo(position_root) == 1)
persisted = t3.session.items(position_root)[1]
assert(persisted.reference.first == 6 and persisted.reference.last == 7)
assert(t3.session.redo(position_root) == 1 and t3.session.undo(position_root) == 1)

-- Unsaved movements must not replace positions corresponding to the file on disk.
vim.api.nvim_buf_set_lines(position_buf, 0, 0, false, { 'not saved' })
assert(t3.session.location(position_root, position_id).pos[1] == 7)
local disk_review = vim.json.decode(
  table.concat(vim.fn.readfile(temp .. '/state/' .. vim.fn.sha256(vim.uv.fs_realpath(position_root)) .. '.json'), '\n')
)
assert(disk_review.items[1].reference.first == 6 and disk_review.items[1].reference.last == 7)
vim.api.nvim_buf_delete(position_buf, { force = true })

trouble.close 't3_review'
vim.fn.delete(temp, 'rf')

print 'Review workflow passed'
vim.cmd 'qa!'
