local M = { icons = true }

local icons = {
  review = '󰈙',
  thread = '󰍪',
  add = '󰐕',
  archive = '󰀼',
  project = '󰉋',
  branch = '',
}

function M.setup(opts)
  M.icons = opts.icons ~= false
  vim.api.nvim_set_hl(0, 'T3ReviewThread', { default = true, link = 'Identifier' })
end

function M.label(kind, text)
  return (M.icons and icons[kind] .. ' ' or '') .. text
end

function M.thread(name)
  return M.label('thread', 'Thread: ') .. (name or 'none selected')
end

return M
