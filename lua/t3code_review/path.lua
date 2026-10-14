local M = {}

function M.canonical(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.root(path)
  if not path and vim.b.t3_review_root then
    return vim.b.t3_review_root
  end
  path = path or vim.api.nvim_buf_get_name(0)
  local start = path ~= '' and path or vim.fn.getcwd()
  return M.canonical(vim.fs.root(start, { '.git' }) or vim.fn.getcwd())
end

return M
