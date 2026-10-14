local Connection = require 't3code_review.connection'
local Appearance = require 't3code_review.appearance'
local M = {}

local picking = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.ERROR, { title = 'nvim-t3code-review' })
end

function M.validate(target, root, done)
  Connection.with_auth(
    'validate',
    { target = target, root = root, environment_id = target.environment_id },
    function(err, result)
      done(err, result and result.target, result)
    end
  )
end

local function choose_model(project, callback)
  if project.defaultModelSelection then
    callback(nil, project.defaultModelSelection)
    return
  end

  Connection.with_auth('models', { environment_id = project.environment_id }, function(err, result)
    if err then
      callback(err)
      return
    end

    local models = {}
    for _, provider in ipairs(result.providers) do
      for _, model in ipairs(provider.models) do
        models[#models + 1] = {
          label = (provider.displayName or provider.providerInstanceId) .. ' · ' .. (model.label or model.id),
          selection = { instanceId = provider.providerInstanceId, provider = provider.driverKind, model = model.id },
        }
      end
    end

    vim.ui.select(models, {
      prompt = 'Model for the new review thread',
      format_item = function(item)
        return item.label
      end,
    }, function(model)
      if model then
        callback(nil, model.selection)
      else
        callback(nil, nil)
      end
    end)
  end)
end

function M.pick(opts, done)
  local root = opts.root
  if picking[root] then
    done(nil)
    return
  end

  picking[root] = true

  local function finish(target)
    picking[root] = nil
    done(target)
  end

  local function failed(err)
    notify(err.message)
    finish(nil)
  end

  local choose_project, choose_thread

  local function new_thread(project, status)
    local function launch()
      vim.ui.input(
            { prompt = 'Review thread title: ', default = 'Code review · ' .. vim.fs.basename(root) },
        function(title)
          if not title or not title:match '%S' then
            finish(nil)
            return
          end

          choose_model(project, function(err, selection)
            if err then
              failed(err)
              return
            end

            if not selection then
              finish(nil)
              return
            end

            Connection.with_auth('create', {
              project_id = project.id,
              environment_id = project.environment_id,
              root = root,
              title = title,
              model_selection = selection,
            }, function(create_err, result)
              if create_err then
                notify(create_err.message)
                choose_thread(project, false)
              else
                notify('Created review thread: ' .. result.target.name, vim.log.levels.INFO)
                finish(result.target)
              end
            end)
          end)
        end
      )
    end

    if status.canCreateThreads then
      launch()
      return
    end

    vim.ui.select(
      { 'Authorize thread creation', 'Cancel' },
      { prompt = 'New threads need T3 operation access' },
      function(choice)
        if choice ~= 'Authorize thread creation' then
          choose_thread(project, false)
          return
        end

        Connection.connect({ force = true, access = 'operate' }, function(err, connected)
          if err then
            failed(err)
          elseif not connected.canCreateThreads then
            failed {
              message = 'The grant is still read-only. Reconnect with thread-creation access; in browser mode, choose Supervised.',
            }
          else
            launch()
          end
        end)
      end
    )
  end

  choose_thread = function(project, settled)
    Connection.with_auth(
      'threads',
      { project_id = project.id, environment_id = project.environment_id, root = root, settled = settled },
      function(err, result)
        if err then
          failed(err)
          return
        end

        local rows = vim.deepcopy(result.threads)
        rows[#rows + 1] = { action = 'new', name = 'New review thread in this checkout' }
        rows[#rows + 1] = { action = 'settled', name = settled and '← Active threads' or 'Browse settled threads…' }
        rows[#rows + 1] = { action = 'project', name = 'Choose another project…' }

        vim.ui.select(rows, {
          prompt = 'T3 review thread · ' .. project.title,
          format_item = function(row)
            if row.action then
              local kind = row.action == 'new' and 'add' or row.action == 'settled' and 'archive' or 'project'
              return Appearance.label(kind, row.name)
            end

            local match = row.same_checkout and 'same checkout' or 'other checkout'
            local branch = type(row.branch) == 'string' and ' · ' .. Appearance.label('branch', row.branch) or ''
            return row.name .. '  [' .. row.status .. ' · ' .. match .. branch .. ']'
          end,
        }, function(row)
          if not row then
            finish(nil)
          elseif row.action == 'project' then
            choose_project(true)
          elseif row.action == 'settled' then
            choose_thread(project, not settled)
          elseif row.action == 'new' then
            new_thread(project, result)
          else
            Connection.with_auth(
              'validate',
              { target = row, root = root, environment_id = row.environment_id },
              function(validate_err, validated)
                if validate_err then
                  notify(validate_err.message)
                  choose_thread(project, settled)
                else
                  finish(validated.target)
                end
              end
            )
          end
        end)
      end
    )
  end

  choose_project = function(force)
    Connection.with_auth('projects', { root = root, path = opts.path or root }, function(err, result)
      if err then
        failed(err)
        return
      end

      if #result.projects == 0 then
        failed { message = 'Register this project in T3 Code first; no projects are available.' }
        return
      end

      for _, project in ipairs(result.projects) do
        project.environment_id = result.environmentId
      end

      local selected
      if not force and opts.project_id then
        for _, project in ipairs(result.projects) do
          if project.id == opts.project_id then
            selected = project
          end
        end
      end

      if not force and not selected then
        local first, second = result.projects[1], result.projects[2]
        if first.score >= 5000 and (not second or first.score > second.score) then
          selected = first
        end
      end

      if selected then
        choose_thread(selected, false)
        return
      end

      vim.ui.select(result.projects, {
        prompt = 'T3 project for this review',
        format_item = function(project)
          return Appearance.label('project', project.title) .. '  [' .. project.match .. ']  ' .. project.workspaceRoot
        end,
      }, function(project)
        if project then
          choose_thread(project, false)
        else
          finish(nil)
        end
      end)
    end)
  end

  choose_project(false)
end

return M
