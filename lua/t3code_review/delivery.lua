local Connection = require 't3code_review.connection'
local Routing = require 't3code_review.routing'
local M = {}

local app = 'T3 Code (Beta)'

function M.setup(name)
  app = name or app
end

function M.build_link(text, target)
  assert(text:match '%S', 'Review text is empty')
  assert(
    vim.str_utfindex(text, 'utf-16') <= 8000,
    'T3 draft links allow 8,000 UTF-16 units; shorten the review comments'
  )
  assert(target and target.environment_id and target.thread_id, 'Choose a T3 thread first')

  local function encode(value)
    return (
      value:gsub('[^A-Za-z0-9%-._~]', function(char)
        return string.format('%%%02X', string.byte(char))
      end)
    )
  end

  return 't3code://threads/'
    .. encode(target.environment_id)
    .. '/'
    .. encode(target.thread_id)
    .. '?prompt='
    .. encode(text)
end

function M.draft(text, target, done)
  local ok, url = pcall(M.build_link, text, target)

  local function finish(err)
    if done then
      done(err)
    elseif err then
      vim.notify(err, vim.log.levels.ERROR, { title = 'nvim-t3code-review' })
    else
      vim.notify(
        'Draft opened in ' .. (target.name or target.thread_id) .. '; send it from T3 Code',
        vim.log.levels.INFO,
        { title = 'nvim-t3code-review' }
      )
    end
  end

  if not ok then
    finish(url)
    return
  end

  -- T3 can consume ?prompt while the previous thread is still mounted.
  -- Its desktop link queue awaits each navigation: open the recipient before its prompt.
  local recipient_url = url:match '^[^?]+'
  if vim.fn.has 'mac' == 1 then
    vim.system({ 'open', '-a', app, recipient_url, url }, { text = true }, function(result)
      vim.schedule(function()
        finish(result.code ~= 0 and result.stderr or nil)
      end)
    end)
  else
    vim.system({ 'xdg-open', recipient_url }, { text = true }, function(navigation)
      if navigation.code ~= 0 then
        vim.schedule(function()
          finish(navigation.stderr)
        end)
        return
      end

      vim.system({ 'xdg-open', url }, { text = true }, function(result)
        vim.schedule(function()
          finish(result.code ~= 0 and result.stderr or nil)
        end)
      end)
    end)
  end

  return url
end

-- The request ID stays stable for an unchanged review, including retries after uncertainty.
local function request_id(root, target, text, submitted)
  local ids = {}
  for _, item in ipairs(submitted) do
    ids[#ids + 1] = item.id
  end

  return 'nvim-review:'
    .. vim.fn.sha256(root .. '\n' .. target.thread_id .. '\n' .. text .. '\n' .. table.concat(ids, '\n'))
end

local function authorize(recipient, mode, done)
  vim.ui.select({ 'Authorize sending', 'Cancel' }, {
    prompt = 'Send to ' .. recipient.name .. ' · requires ' .. mode .. ' access',
  }, function(choice)
    if choice ~= 'Authorize sending' then
      done(nil, false)
      return
    end

    Connection.connect({ force = true, access = 'operate', runtime_mode = mode }, function(err)
      done(err, not err)
    end)
  end)
end

function M.send(root, target, text, submitted, done)
  Routing.validate(target, root, function(err, recipient, status)
    if err then
      done(err)
      return
    end

    local params = {
      target = recipient,
      environment_id = recipient.environment_id,
      text = text,
      request_id = request_id(root, recipient, text, submitted),
    }
    local authorized = false
    local send

    local function obtain_access()
      authorize(recipient, status.runtimeMode or 'approval-required', function(auth_err, approved)
        if auth_err or not approved then
          done(auth_err)
          return
        end

        authorized = true
        send()
      end)
    end

    send = function()
      Connection.with_auth('send', params, function(send_err, receipt)
        local needs_access = send_err
          and (send_err.code == 'OPERATION_ACCESS_REQUIRED' or send_err.code == 'runtime_mode_escalation_denied')

        if needs_access and not authorized then
          obtain_access()
        else
          done(send_err, receipt)
        end
      end)
    end

    if status.canCreateThreads then
      send()
    else
      obtain_access()
    end
  end)
end

return M
