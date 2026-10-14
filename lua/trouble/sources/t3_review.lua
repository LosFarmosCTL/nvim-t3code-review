local M = {}
local active_root

function M.open(root, opts)
  opts = opts or {}
  local trouble = require 'trouble'
  if active_root and active_root ~= root then
    trouble.close 't3_review'
  end

  active_root = root
  local view = trouble.open { mode = 't3_review', focus = opts.focus == true, params = { root = root } }
  if view then
    view:wait(function()
      if view.win.buf then
        vim.b[view.win.buf].t3_review_root = root
      end
    end)
  end

  return view
end

local function root(view)
  return view.opts.params.root
end

function M.header(checkout)
  local review = require('t3code_review.session').get(checkout)
  local count = #review.items
  return 'Code Review · '
    .. count
    .. (count == 1 and ' comment' or ' comments')
    .. ' → '
    .. (review.target and review.target.name or 'choose a thread')
end

M.config = {
  modes = {
    t3_review = {
      mode = 'diagnostics',
      desc = 'Code Review',
      title = false,
      source = 't3_review',
      config = function(opts)
        opts.params = opts.params or {}
        opts.params.root = opts.params.root or require('t3code_review.path').root()

        opts.win.wo = opts.win.wo or {}
        opts.win.wo.winbar = "%{v:lua.require'trouble.sources.t3_review'.header("
          .. string.format('%q', opts.params.root)
          .. ')}%=%#Comment#e edit · dd remove · s draft · S send · C clear · t switch thread · ? help%*'
      end,
      open_no_results = true,
      warn_no_results = false,
      max_items = math.huge,
      groups = { { 'filename', format = '{file_icon} {filename} {count}' } },
      sort = { 'filename', 'pos', 'review_order' },
      format = '{text} {pos}',
      events = {
        { event = 'User', pattern = 'T3ReviewChanged' },
        { event = 'TextChanged', main = true },
        { event = 'TextChangedI', main = true },
      },
      keys = {
        e = {
          desc = 'Edit review comment',
          action = function(view, ctx)
            if ctx.item then
              require('t3code_review').edit_review(ctx.item.item.review_id, { root = root(view) })
            end
          end,
        },
        dd = {
          desc = 'Remove review comment',
          action = function(view, ctx)
            if ctx.item then
              require('t3code_review.session').remove(root(view), ctx.item.item.review_id)
            end
          end,
        },
        s = {
          desc = 'Stage review as draft',
          action = function(view)
            require('t3code_review').stage_review { root = root(view) }
          end,
        },
        S = {
          desc = 'Send review',
          action = function(view)
            require('t3code_review').send_review { root = root(view) }
          end,
        },
        C = {
          desc = 'Clear review',
          action = function(view)
            require('t3code_review').clear_review { root = root(view) }
          end,
        },
        t = {
          desc = 'Switch thread',
          action = function(view)
            require('t3code_review').review_thread { root = root(view) }
          end,
        },
      },
    },
  },
}

function M.get(cb, ctx)
  local session = require 't3code_review.session'
  local checkout = ctx.opts.params.root
  local items = {}
  for order, entry in ipairs(session.items(checkout)) do
    local location = session.location(checkout, entry.id)
    items[#items + 1] = require('trouble.item').new {
      id = 't3_review:' .. entry.id,
      source = 't3_review',
      filename = entry.reference.path,
      buf = location.buf or vim.fn.bufadd(entry.reference.path),
      pos = location.pos,
      end_pos = location.end_pos,
      item = { text = entry.comment, review_id = entry.id, review_order = order },
    }
  end

  cb(items)
end

return M
