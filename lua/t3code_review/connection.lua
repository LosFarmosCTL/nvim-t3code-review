local source = debug.getinfo(1, 'S').source:sub(2)
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local config = { node = 'node', auth_method = 'auto', storage_dir = vim.fn.stdpath 'state' .. '/t3/connections' }

local M = {}
local jobs = {}
local connecting = false
local connect_waiters = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = 'nvim-t3code-review' })
end

local function authorization_progress(event)
  local mode = event.runtimeMode or 'approval-required'
  local operating = event.access == 'operate'

  if event.type == 'local_authorization' then
    local access = operating and mode .. ' operation access' or 'read-only access'
    notify("Connecting through T3's local CLI with " .. access .. '…')
    return
  end

  if event.reason then
    notify(event.reason .. ' Using browser authorization.')
  end

  local instruction = operating and "In T3's approval page, approve " .. mode .. ' access.'
    or "In T3's browser page, leave Read only selected."
  instruction = instruction
    .. ' If asked, create a pairing code in T3 Settings → Connections, paste it, and click Approve.'
  if not operating then
    instruction = instruction .. ' Then use :T3SelectThread to choose a review thread.'
  end

  notify(instruction)
  vim.ui.open(event.url)
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
end

function M.request(operation, params, done)
  local pending = ''
  local result, failure

  local function parse(line)
    if line == '' then
      return
    end

    local ok, event = pcall(vim.json.decode, line, { luanil = { object = true } })
    if not ok then
      failure = { code = 'BRIDGE_FAILED', message = 'The T3 bridge returned invalid JSON.' }
      return
    end

    if event.type == 'authorization' or event.type == 'local_authorization' then
      vim.schedule(function()
        authorization_progress(event)
      end)
    elseif event.type == 'result' then
      result = event.result
    elseif event.type == 'error' then
      failure = event.error
    end
  end

  local payload = {
    operation = operation,
    params = params or {},
    options = {
      origin = config.origin,
      runtime_file = config.runtime_file,
      storage_dir = config.storage_dir,
      auth_method = config.auth_method,
      cli_path = config.cli_path,
      environment_id = params and params.environment_id,
    },
  }

  local job
  local ok, err = pcall(function()
    job = vim.system({ config.node, plugin_root .. '/scripts/bridge.mjs' }, {
      stdin = vim.json.encode(payload),
      text = true,
      timeout = operation == 'connect' and 310000 or 120000,
      stdout = function(_, chunk)
        if not chunk then
          return
        end

        pending = pending .. chunk
        while pending:find('\n', 1, true) do
          local boundary = pending:find('\n', 1, true)
          parse(pending:sub(1, boundary - 1))
          pending = pending:sub(boundary + 1)
        end
      end,
    }, function()
      if pending ~= '' then
        parse(pending)
      end

      vim.schedule(function()
        if job then
          jobs[job] = nil
        end

        if not failure and not result then
          failure = {
            code = 'BRIDGE_FAILED',
            message = 'T3 bridge could not run. Check Node.js and run npm ci --ignore-scripts in ' .. plugin_root,
          }
        end

        done(failure, result)
      end)
    end)
  end)

  if not ok then
    vim.schedule(function()
      done { code = 'BRIDGE_FAILED', message = 'Could not start the T3 bridge: ' .. tostring(err) }
    end)
    return
  end

  jobs[job] = true
  return job
end

function M.connect(opts, done)
  opts = opts or {}
  if done then
    connect_waiters[#connect_waiters + 1] = done
  end

  if connecting then
    notify 'T3 authorization is already in progress'
    return
  end

  connecting = true
  M.request('connect', opts, function(err, status)
    connecting = false
    if err then
      notify(err.message, vim.log.levels.ERROR)
    else
      notify(
        'Connected to ' .. status.label .. (status.canCreateThreads and ' (operation access enabled)' or ' (read-only)')
      )
    end

    local waiters = connect_waiters
    connect_waiters = {}
    for _, waiting in ipairs(waiters) do
      waiting(err, status)
    end
  end)
end

function M.with_auth(operation, params, done)
  M.request(operation, params, function(err, result)
    if err and err.code == 'AUTH_REQUIRED' then
      M.connect({}, function(auth_err)
        if auth_err then
          done(auth_err)
        else
          M.request(operation, params, done)
        end
      end)
    else
      done(err, result)
    end
  end)
end

function M.doctor()
  M.request('doctor', {}, function(err, status)
    if err then
      notify(err.message, vim.log.levels.ERROR)
      return
    end

    notify(table.concat({
      status.label .. ' · ' .. status.serverVersion,
      'Orchestrator protocol: ' .. status.orchestrationProtocolVersion,
      'Connection: ' .. (status.authenticated and 'authenticated' or 'run :T3Connect'),
      'Authentication: ' .. (status.authMethod or config.auth_method),
      'Local CLI: ' .. (status.localCliAvailable and status.cliPath or (status.localCliReason or 'unavailable')),
      'New threads: ' .. (status.canCreateThreads and 'enabled' or 'requires operation access'),
    }, '\n'))
  end)
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  callback = function()
    for job in pairs(jobs) do
      pcall(function()
        job:kill(15)
      end)
    end
  end,
})

return M
