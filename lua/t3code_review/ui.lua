local M = {}
local Appearance = require 't3code_review.appearance'

---A normal Neovim buffer for multiline review comments.
---save(comment, done) calls done(error) to retain the popup, or done(nil) to close.
function M.comment(opts)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(opts.comment or '', '\n', { plain = true }))

  local width = math.max(1, math.min(76, vim.o.columns - 4))
  local height = math.max(1, math.min(10, vim.o.lines - 5))
  local function title()
    local chunks = { { ' ' .. (opts.title or 'Add review comment') } }
    if opts.recipient then
      chunks[#chunks + 1] = { ' · ' .. Appearance.label('thread', 'Thread: ') }
      chunks[#chunks + 1] = { opts.recipient() or 'none selected', 'T3ReviewThread' }
    end
    chunks[#chunks + 1] = { ' ' }
    return chunks
  end

  local window = vim.api.nvim_open_win(buffer, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = title(),
    title_pos = 'center',
    footer_pos = 'center',
    footer = ' <C-s> '
      .. (opts.action or 'add to review')
      .. (opts.thread and ' · <C-t> switch thread' or '')
      .. ' ',
  })
  vim.wo[window].wrap = true
  vim.wo[window].winbar = height > 1 and ' ' or ''
  vim.wo[window].foldcolumn = tostring(math.min(2, width - 1))
  vim.wo[window].foldenable = false
  vim.wo[window].statuscolumn = '  '
  local highlights = vim.wo[window].winhighlight
  vim.wo[window].winhighlight = (highlights ~= '' and highlights .. ',' or '')
    .. 'WinBar:NormalFloat,WinBarNC:NormalFloat,FoldColumn:NormalFloat'

  local saving = false
  local function close()
    if vim.api.nvim_win_is_valid(window) then
      vim.cmd.stopinsert()
      vim.api.nvim_win_close(window, true)
    end
  end

  vim.keymap.set('n', 'q', close, { buffer = buffer, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buffer, nowait = true })
  vim.keymap.set({ 'n', 'i' }, '<C-c>', close, { buffer = buffer })

  if opts.thread then
    vim.keymap.set({ 'n', 'i' }, '<C-t>', function()
      opts.thread(function()
        if vim.api.nvim_win_is_valid(window) then
          vim.api.nvim_win_set_config(window, { title = title() })
        end
      end)
    end, { buffer = buffer })
  end

  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    if saving then
      return
    end

    local comment = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n')
    if not comment:match '%S' then
      vim.notify('Add a review comment first', vim.log.levels.WARN, { title = 'nvim-t3code-review' })
      return
    end

    saving = true
    local function done(err)
      saving = false
      if err then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = 'nvim-t3code-review' })
        return
      end
      close()
    end

    local ok, err = pcall(opts.save, comment, done)
    if not ok then
      done(err)
    end
  end, { buffer = buffer })

  vim.cmd.startinsert()
  return { buf = buffer, win = window }
end

return M
