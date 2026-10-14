local Path = require 't3code_review.path'
local Session = require 't3code_review.session'
local Connection = require 't3code_review.connection'
local Routing = require 't3code_review.routing'
local UI = require 't3code_review.ui'
local Delivery = require 't3code_review.delivery'

local M = {}
local sending = {}

local function notify(message)
  vim.notify(message, vim.log.levels.INFO, { title = 'nvim-t3code-review' })
end

local function run(fn)
  local ok, result = pcall(fn)
  if not ok then
    vim.notify(result, vim.log.levels.ERROR, { title = 'nvim-t3code-review' })
    return
  end

  return result
end

local function review_window(root, focus)
  return require('trouble.sources.t3_review').open(root, { focus = focus })
end

local function capture_reference(opts)
  opts = opts or {}
  local buf = opts.bufnr or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  assert(path ~= '', 'Save this buffer to a named file before reviewing it')

  local first, last = opts.first or 1, opts.last or vim.api.nvim_buf_line_count(buf)
  if opts.visual then
    local mode = vim.fn.mode()
    assert(
      buf == vim.api.nvim_get_current_buf() and (mode == 'v' or mode == 'V' or mode == '\22'),
      'Enter Visual mode first'
    )
    local start, finish = vim.fn.getpos('v')[2], vim.fn.getpos('.')[2]
    first, last = math.min(start, finish), math.max(start, finish)
    vim.cmd.normal { args = { '\27' }, bang = true }
  end

  assert(first >= 1 and last >= first and last <= vim.api.nvim_buf_line_count(buf), 'Invalid review range')

  return {
    path = path,
    root = Path.root(path),
    first = first,
    last = last,
    bufnr = buf,
    whole_file = not opts.visual and opts.first == nil and opts.last == nil,
  }
end

function M.select_thread(opts, done)
  opts = opts or {}
  local root = opts.root or Path.root()
  local saved = Session.get(root).target

  Routing.pick({ root = root, path = opts.path or root, project_id = saved and saved.project_id }, function(target)
    run(function()
      if target then
        Session.set_target(root, target)
      end

      if done then
        done(target)
      end
    end)
  end)
end

local function with_target(root, path, done)
  local target = Session.get(root).target
  if target then
    done(target)
  else
    M.select_thread({ root = root, path = path }, done)
  end
end

function M.show_review(opts)
  return run(function()
    opts = opts or {}
    local session = Session.get(opts.root)

    local path = vim.api.nvim_buf_get_name(0)
    local view = review_window(session.root, true)
    if view and not Session.get(session.root).target then
      view:wait(function()
        M.select_thread { root = session.root, path = path }
      end)
    end

    return Session.get(session.root)
  end)
end

local function comment(reference, text, action, save, title)
  UI.comment {
    comment = text,
    action = action,
    title = title or 'Add review comment',
    recipient = function()
      local target = Session.get(reference.root).target
      return target and target.name or nil
    end,
    thread = function(updated)
      M.select_thread({ root = reference.root }, updated)
    end,
    save = save,
  }
end

local function stage(text, target, root, done)
  Routing.validate(target, root, function(err, recipient)
    if err then
      if done then
        done(err.message)
      else
        vim.notify(err.message, vim.log.levels.ERROR)
      end

      return
    end

    run(function()
      Session.set_target(root, recipient)
      M.draft(text, recipient, done)
    end)
  end)
end

function M.add_comment(opts)
  return run(function()
    opts = opts or {}
    local reference = capture_reference(opts)
    with_target(reference.root, reference.path, function(target)
      if not target then
        return
      end

      comment(reference, opts.comment, 'add to review', function(text, done)
        Session.add(reference, text)
        done(nil)
        review_window(reference.root)
      end)
    end)
  end)
end

function M.edit_comment(id, opts)
  return run(function()
    for _, item in ipairs(Session.items(opts and opts.root)) do
      if item.id == id then
        comment(item.reference, item.comment, 'save comment', function(text, done)
          Session.edit(item.reference.root, id, text)
          done(nil)
        end, 'Edit review comment')
        return
      end
    end

    error 'Review comment no longer exists'
  end)
end

function M.draft_review(opts)
  return run(function()
    opts = opts or {}
    local root = opts.root or Path.root()
    local text = Session.format(root)

    with_target(root, root, function(target)
      if target then
        stage(text, target, root, opts.done)
      end
    end)
  end)
end

function M.clear_review(opts)
  return run(function()
    local count = Session.clear(opts and opts.root)
    notify('Cleared ' .. count .. ' review comments')
    return count
  end)
end

function M.send_review(opts)
  return run(function()
    opts = opts or {}
    local root = Session.get(opts.root).root
    if sending[root] then
      notify 'This review is already being sent'
      return
    end

    local text = Session.format(root)
    local submitted = vim.deepcopy(Session.items(root))
    sending[root] = true

    local function finish(err, receipt)
      sending[root] = nil
      if err then
        vim.notify(err.message, vim.log.levels.ERROR, { title = 'nvim-t3code-review' })
      elseif receipt then
        local ok, clear_err = pcall(Session.clear, root, submitted)
        if not ok then
          vim.notify('Review sent, but local comments could not be cleared: ' .. clear_err, vim.log.levels.ERROR)
        else
          notify('Review sent (' .. receipt.delivery .. '); submitted comments cleared')
        end
      end

      if opts.done then
        opts.done(err, receipt)
      end
    end

    with_target(root, root, function(target)
      if not target then
        finish()
        return
      end

      Delivery.send(root, target, text, submitted, finish)
    end)
  end)
end

function M.draft_comment(opts)
  return run(function()
    opts = opts or {}
    local reference = capture_reference(opts)

    with_target(reference.root, reference.path, function(target)
      if target then
        comment(reference, opts.comment, 'stage draft', function(text, done)
          stage(Session.format_reference(reference, text), Session.get(reference.root).target, reference.root, done)
        end)
      end
    end)
  end)
end

function M.send_comment(opts)
  return run(function()
    opts = opts or {}
    local reference = capture_reference(opts)
    -- Keep retries stable within this popup, but allow identical comments in separate sends.
    local submitted = { { id = 'comment:' .. tostring(vim.uv.hrtime()) } }

    with_target(reference.root, reference.path, function(target)
      if target then
        comment(reference, opts.comment, 'send comment', function(text, done)
          Delivery.send(
            reference.root,
            Session.get(reference.root).target,
            Session.format_reference(reference, text),
            submitted,
            function(err, receipt)
              done(err and err.message or not receipt and 'Comment was not sent' or nil)
              if receipt then
                notify('Comment sent (' .. receipt.delivery .. ')')
              end
              if opts.done then
                opts.done(err, receipt)
              end
            end
          )
        end)
      end
    end)
  end)
end

M.session = Session
M.build_link, M.draft = Delivery.build_link, Delivery.draft
M.connect, M.doctor = Connection.connect, Connection.doctor

function M.setup(opts)
  opts = opts or {}
  require('t3code_review.appearance').setup(opts)
  Delivery.setup(opts.app)
  Connection.setup(opts.connection)
  Session.setup(opts.review)

  for name, action in pairs {
    T3ShowReview = M.show_review,
    T3SelectThread = M.select_thread,
    T3DraftReview = M.draft_review,
    T3Doctor = M.doctor,
    T3ClearReview = M.clear_review,
    T3SendReview = M.send_review,
  } do
    vim.api.nvim_create_user_command(name, function()
      action()
    end, {})
  end

  for name, action in pairs {
    T3DraftComment = M.draft_comment,
    T3SendComment = M.send_comment,
    T3AddComment = M.add_comment,
  } do
    vim.api.nvim_create_user_command(name, function(args)
      action { first = args.range > 0 and args.line1 or nil, last = args.range > 0 and args.line2 or nil }
    end, { range = true })
  end

  vim.api.nvim_create_user_command('T3Connect', function(args)
    M.connect { force = args.bang, method = args.args ~= '' and args.args or nil }
  end, {
    bang = true,
    nargs = '?',
    complete = function()
      return { 'auto', 'cli', 'browser' }
    end,
  })
end

return M
