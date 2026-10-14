# nvim-t3code-review

Review code in Neovim and send your feedback to [T3 Code](https://github.com/pingdotgg/t3code).

Select code, write a comment, and keep reviewing. Your comments appear in a navigable **Code Review** window powered by [Trouble.nvim](https://github.com/folke/trouble.nvim). When you're ready, hand the review to a T3 thread as an editable draft or send it directly.

The agent receives file links, line references, and your comments. It reads the code from your checkout itself.

https://github.com/user-attachments/assets/5420ea42-c19b-4dc6-b85e-ef662ebc43f5

## ✨ Features

- Comment on a visual selection, a specific line, or a whole file.
- Collect multiple comments and navigate their locations with Trouble's previews.
- Choose a T3 thread per checkout and switch recipients without losing your comments.
- Find matching projects and Git worktrees automatically.
- Continue an existing thread or create a new review thread.
- Stage a draft in T3's composer or send the review directly.
- Resume saved reviews across Neovim sessions.
- Use editor commands or the Lua API with your own key mappings.

## ⚡ Requirements

- Neovim **0.11+**.
- Node.js **22+** and npm.
- [Trouble.nvim](https://github.com/folke/trouble.nvim) **v3**.
- A running **local T3 Code** with Orchestrator V2 support (as of writing, this is only available in the nightly version), with your project registered in T3.
- Git for matching related worktrees and repositories.

Draft handoff uses `open` on macOS and `xdg-open` on Linux. The default macOS application is `T3 Code (Nightly)`; change `app` if yours has a different name.

## 📦 Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

Add this spec to your plugin configuration. The mappings are suggestions; the plugin does not install global key mappings itself.

```lua
{
  'LosFarmosCTL/nvim-t3code-review',
  dependencies = { 'folke/trouble.nvim' },
  build = 'npm ci --ignore-scripts --no-audit --no-fund',
  opts = {},
  cmd = {
    'T3AddComment', 'T3ShowReview', 'T3DraftReview',
    'T3SendReview', 'T3ClearReview', 'T3DraftComment', 'T3SendComment',
    'T3SelectThread', 'T3Connect', 'T3Doctor',
  },
  keys = {
    {
      '<leader>ra',
      function() require('t3code_review').add_comment { visual = true } end,
      mode = 'x',
      desc = 'Add review comment to selection',
    },
    { '<leader>ra', '<cmd>.T3AddComment<cr>', desc = 'Add review comment to current line' },
    { '<leader>rf', '<cmd>T3AddComment<cr>', desc = 'Add review comment to file' },
    { '<leader>rr', '<cmd>T3ShowReview<cr>', desc = 'Show code review' },
    { '<leader>rt', '<cmd>T3SelectThread<cr>', desc = 'Switch review thread' },
    { '<leader>rd', '<cmd>T3DraftReview<cr>', desc = 'Stage review draft' },
    { '<leader>rS', '<cmd>T3SendReview<cr>', desc = 'Send review' },
    { '<leader>rx', '<cmd>T3ClearReview<cr>', desc = 'Clear review comments' },
    { '<leader>rc', '<cmd>T3Connect<cr>', desc = 'Connect to T3 Code' },
  },
}
```

With another package manager, the general steps to get everything to work properly are to install Trouble.nvim, run `npm ci --ignore-scripts` in this plugin's directory, and call `require('t3code_review').setup()`, depending on the package manager this might be more or less easily automatable.

## 🚀 Usage

### Your first review

1. Open T3 Code and register the project you want to review.
2. Open a file from that checkout in Neovim, select some lines, and press `<leader>ra`, or run `:'<,'>T3AddComment`.
3. Choose the destination thread. On first use, the plugin connects to T3 automatically.
4. Write your feedback in **Add review comment** and press `<C-s>` to add it to the review. Code Review opens when you save the comment.
5. Repeat for other parts of the code. Open `:T3ShowReview` to navigate or edit your comments.
6. Press **s** in Code Review to open a draft in T3, or **S** to send directly.

Save the files you've edited before handing off the review so the agent can read your changes from disk.

### Comment popup

The popup title shows the selected thread.

| Key                  | Action                                  |
| -------------------- | --------------------------------------- |
| `Ctrl-S`             | Add the comment, or save an edit        |
| `Ctrl-T`             | Switch thread while keeping the comment |
| `Ctrl-C`             | Cancel                                  |
| `q` in Normal mode   | Cancel                                  |
| `Esc` in Normal mode | Cancel                                  |

### Code Review window

Comments are grouped by file. Move through them to preview their locations using Trouble's normal preview behavior. The header shows the comment count and destination thread.

| Key  | Action                      |
| ---- | --------------------------- |
| `e`  | Edit the selected comment   |
| `dd` | Remove the selected comment |
| `s`  | Stage the review as a draft |
| `S`  | Send the review directly    |
| `C`  | Clear all comments          |
| `t`  | Switch thread               |
| `?`  | Show shortcut help          |

Trouble's usual navigation, preview, and folding controls remain available. The review view inherits your diagnostics-mode configuration.

### Choosing a thread

The picker prioritizes projects matching the selected file or checkout, including related Git worktrees. Threads in the same checkout appear first. You can also browse settled threads, choose another project, or create a new review thread.

Your chosen thread is saved per checkout. Use `:T3SelectThread`, **t** in Code Review, or **Ctrl-T** in the comment popup to change it.

A new thread uses the current checkout and the project's default model, or asks you to choose a model. It starts idle; adding comments does not start an agent run.

### Draft or send?

|                  | Draft (`s`)                         | Send (`S`)                                   |
| ---------------- | ----------------------------------- | -------------------------------------------- |
| Destination      | T3's message input                  | A new turn in the chosen thread              |
| Starts the agent | When you press Send in T3           | Immediately, or queued behind an active turn |
| Local comments   | Kept until you remove or clear them | Cleared after confirmed delivery             |
| Message limit    | 8,000 UTF-16 units                  | 120,000 characters                           |

Sending a staged draft from T3 does **not** clear the local review. Use `:T3ClearReview` or **C** when you're done. Clearing comments keeps the selected thread.

### What the agent receives

Comments for the same file stay together; different files are separated by a horizontal rule:

```markdown
[service.lua](lua/service.lua:21-32)
Move retry ownership into the service.

[service.lua](lua/service.lua:45)
Can this error include the request ID?

---

[config.lua](lua/config.lua)
Keep the defaults in one place.
```

Only references and comments are sent. Whole-file comments omit the line suffix.

## ⚙️ Configuration

With lazy.nvim, put overrides in `opts`. Otherwise, pass them to `setup()`:

```lua
require('t3code_review').setup {
  icons = true, -- Set false to disable Nerd Font icons
  app = 'T3 Code (Nightly)',
  connection = {
    node = 'node',
    auth_method = 'auto', -- 'auto', 'cli', or 'browser'
    storage_dir = vim.fn.stdpath('state') .. '/t3/connections',
    -- cli_path = vim.fn.expand('~/.t3/bin/t3'),
    -- runtime_file = vim.fn.expand('~/.t3/userdata/server-runtime.json'),
    -- origin = 'http://127.0.0.1:3773',
  },
  review = {
    storage_dir = vim.fn.stdpath('state') .. '/t3/reviews',
  },
}
```

Leave `origin`, `runtime_file`, and `cli_path` unset for automatic discovery. Set `node` to an executable path if Node.js isn't on Neovim's `PATH`.

### Authentication

By default, the plugin connects through T3's app-managed CLI, normally `~/.t3/bin/t3`. If the CLI is unavailable, it opens your default browser. Approve **Read only**; if asked for a pairing code, create one in **T3 Settings → Connections**.

Reading projects and threads uses read-only access. Creating a thread requests **Supervised** operation access. Sending requests operation access matching the destination thread's runtime mode. The plugin prompts when additional access is needed.

Use `:T3Connect!` to reconnect or `:T3Connect! browser` to force browser authorization. Run `:T3Doctor` to check the detected server, CLI, and connection status.

### Saved reviews

Reviews are stored as JSON under `stdpath('state')/t3/reviews`, one file per canonical checkout path. Each review contains comments, file/line references, and its selected thread. Line references follow buffer edits during the current Neovim session.

Connection credentials are stored separately under `stdpath('state')/t3/connections` in private files.

## Commands

| Command                             | Action                                                               |
| ----------------------------------- | -------------------------------------------------------------------- |
| `:T3AddComment`                      | Add a comment on the whole file                                      |
| `:21,32T3AddComment`                 | Add a comment on a line range                                        |
| `:T3ShowReview`                      | Open and focus Code Review                                           |
| `:T3DraftReview`                     | Stage all comments in T3's composer                                   |
| `:T3SendReview`                      | Send all comments directly                                           |
| `:T3ClearReview`                     | Clear comments, keeping the selected thread                          |
| `:T3DraftComment`                    | Write and draft one comment, keeping the collected review unchanged   |
| `:T3SendComment`                     | Write and send one comment, keeping the collected review unchanged    |
| `:T3SelectThread`                    | Choose another thread                                                |
| `:T3Connect[!] [auto\|cli\|browser]` | Connect, or force a new connection with `!`                           |
| `:T3Doctor`                         | Show connection details                                              |

Like `T3AddComment`, `T3DraftComment` and `T3SendComment` accept a line range or a Visual selection. Without a range, they reference the whole file. A failed or canceled direct send keeps the comment popup open so you can retry.

## Lua API

```lua
local review = require 't3code_review'

review.show_review()                   -- Open and focus Code Review
review.add_comment { visual = true }   -- Comment on the active Visual selection
review.add_comment { first = 21, last = 32 }
review.add_comment()                   -- Comment on the whole file
review.select_thread()                 -- Choose the thread used for the review
review.draft_review()                  -- Draft the collected comments
review.send_review()                   -- Send the collected comments
review.clear_review()                  -- Clear all comments

review.draft_comment { first = 21, last = 32 } -- Draft a single comment immediately
review.send_comment { first = 21, last = 32 }  -- Send a single comment directly
```

`add_comment()`, `draft_comment()`, and `send_comment()` accept `bufnr` and an initial `comment`. Review operations such as `show_review()`, `draft_review()`, `send_review()`, and `clear_review()` accept a `root` to operate on a specific checkout. Both send operations accept `done(err, receipt)`, called when a send attempt completes; canceling authorization returns no error and no receipt.

For direct access to saved entries, use `review.session.get(root)` or `review.session.items(root)`. Edit an entry with `review.edit_comment(id, { root = root })`. `review.draft(text, target)` opens arbitrary text as a draft; `target` contains `environment_id` and `thread_id`.

## Troubleshooting

- **Can't connect?** Open T3 Code, run `:T3Doctor`, and check that your installed version supports Orchestrator V2 (as of writing this README this requires the nighly version of T3 Code). Use `:T3Connect!` to replace an expired or revoked grant.
- **The bridge won't start?** Check that Neovim can run Node.js 22+, and run `npm ci --ignore-scripts` in the plugin directory.
- **No matching project?** Register the checkout in T3 Code, then run `:T3SelectThread` again.
- **Draft too long?** Shorten the comments or use direct sending, which has a larger message limit.
- **Thread creation wasn't confirmed?** Check T3's thread list before trying again; the thread may already exist.

## Development

Run `npm test` for the editor workflow check. It uses your installed Trouble.nvim and a stubbed T3 connection.

`npm run check:live` checks authentication and project/thread discovery against the running app. It reads only; it never creates a thread or sends a message.

## License

[MIT](LICENSE) © 2026 LosFarmosCTL
