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
    'T3ReviewStart', 'T3ReviewAdd', 'T3ReviewList', 'T3ReviewDraft',
    'T3ReviewSend', 'T3ReviewClear', 'T3Review', 'T3Thread', 'T3Connect', 'T3Doctor',
  },
  keys = {
    { '<leader>rs', '<cmd>T3ReviewStart<cr>', desc = 'Start/resume code review' },
    {
      '<leader>ra',
      function() require('t3code_review').add_review { visual = true } end,
      mode = 'x',
      desc = 'Add review comment to selection',
    },
    { '<leader>ra', '<cmd>.T3ReviewAdd<cr>', desc = 'Add review comment to current line' },
    { '<leader>rf', '<cmd>T3ReviewAdd<cr>', desc = 'Add review comment to file' },
    { '<leader>rr', '<cmd>T3ReviewList<cr>', desc = 'Show code review' },
    { '<leader>rt', '<cmd>T3Thread<cr>', desc = 'Switch review thread' },
    { '<leader>rd', '<cmd>T3ReviewDraft<cr>', desc = 'Stage review draft' },
    { '<leader>rS', '<cmd>T3ReviewSend<cr>', desc = 'Send review' },
    { '<leader>rx', '<cmd>T3ReviewClear<cr>', desc = 'Clear review comments' },
    { '<leader>rc', '<cmd>T3Connect<cr>', desc = 'Connect to T3 Code' },
  },
}
```

With another package manager, the general steps to get everything to work properly are to install Trouble.nvim, run `npm ci --ignore-scripts` in this plugin's directory, and call `require('t3code_review').setup()`, depending on the package manager this might be more or less easily automatable.

## 🚀 Usage

### Your first review

1. Open T3 Code and register the project you want to review.
2. Open a file from that checkout in Neovim and run `:T3ReviewStart`.
3. Choose the destination thread. On first use, the plugin connects to T3 automatically.
4. Select some lines in Visual mode and press `<leader>ra`, or run `:'<,'>T3ReviewAdd`.
5. Write your feedback in **Add review comment** and press **Ctrl-S** to add it to the review.
6. Repeat for other parts of the code. Open `:T3ReviewList` to navigate or edit your comments.
7. Press **s** in Code Review to open a draft in T3, or **S** to send directly.

Save the files you've edited before handing off the review so the agent can read your changes from disk.

### Comment popup

The popup title shows the selected thread.

| Key                | Action                                  |
| ------------------ | --------------------------------------- |
| `Ctrl-S`           | Add the comment, or save an edit        |
| `Ctrl-T`           | Switch thread while keeping the comment |
| `Ctrl-C`           | Cancel                                  |
| `q` in Normal mode | Cancel                                  |

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

Your chosen thread is saved per checkout. Use `:T3Thread`, **t** in Code Review, or **Ctrl-T** in the comment popup to change it.

A new thread uses the current checkout and the project's default model, or asks you to choose a model. It starts idle; adding comments does not start an agent run.

### Draft or send?

|                  | Draft (`s`)                         | Send (`S`)                                   |
| ---------------- | ----------------------------------- | -------------------------------------------- |
| Destination      | T3's message input                  | A new turn in the chosen thread              |
| Starts the agent | When you press Send in T3           | Immediately, or queued behind an active turn |
| Local comments   | Kept until you remove or clear them | Cleared after confirmed delivery             |
| Message limit    | 8,000 UTF-16 units                  | 120,000 characters                           |

Sending a staged draft from T3 does **not** clear the local review. Use `:T3ReviewClear` or **C** when you're done. Clearing comments keeps the selected thread.

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

| Command                              | Action                                                                 |
| ------------------------------------ | ---------------------------------------------------------------------- |
| `:T3ReviewStart`                     | Start or resume the current checkout's review                          |
| `:T3ReviewAdd`                       | Add a comment on the whole file                                        |
| `:21,32T3ReviewAdd`                  | Add a comment on a line range                                          |
| `:T3ReviewList`                      | Open and focus Code Review                                             |
| `:T3ReviewDraft`                     | Stage all comments in T3's composer                                    |
| `:T3ReviewSend`                      | Send all comments directly                                             |
| `:T3ReviewClear`                     | Clear comments, keeping the selected thread                            |
| `:T3Review`                          | Write a comment and draft it without adding it to the collected review |
| `:T3Thread`                          | Choose another thread                                                  |
| `:T3Connect[!] [auto\|cli\|browser]` | Connect, or force a new connection with `!`                            |
| `:T3Doctor`                          | Show connection details                                                |

Like `T3ReviewAdd`, `T3Review` accepts a line range or a Visual selection.

## Lua API

```lua
local review = require 't3code_review'

review.start_review()                  -- Open/resume the review
review.start_review { focus = true }   -- Focus its Trouble window
review.add_review { visual = true }    -- Comment on the active Visual selection
review.add_review { first = 21, last = 32 }
review.add_review()                    -- Comment on the whole file
review.review_thread()                 -- Choose a recipient
review.stage_review()                  -- Draft the collected comments
review.send_review()                   -- Send the collected comments
review.clear_review()                  -- Clear comments, keep the recipient

review.review { first = 21, last = 32 } -- Draft a single comment immediately
```

`add_review()` and `review()` accept `bufnr` and an initial `comment`. Review operations such as `start_review()`, `stage_review()`, `send_review()`, and `clear_review()` accept a `root` to operate on a specific checkout.

For direct access to saved entries, use `review.session.get(root)` or `review.session.items(root)`. Edit an entry with `review.edit_review(id, { root = root })`. `review.draft(text, target)` opens arbitrary text as a draft; `target` contains `environment_id` and `thread_id`.

## Troubleshooting

- **Can't connect?** Open T3 Code, run `:T3Doctor`, and check that your installed version supports Orchestrator V2 (as of writing this README this requires the nighly version of T3 Code). Use `:T3Connect!` to replace an expired or revoked grant.
- **The bridge won't start?** Check that Neovim can run Node.js 22+, and run `npm ci --ignore-scripts` in the plugin directory.
- **No matching project?** Register the checkout in T3 Code, then run `:T3Thread` again.
- **Draft too long?** Shorten the comments or use direct sending, which has a larger message limit.
- **Thread creation wasn't confirmed?** Check T3's thread list before trying again; the thread may already exist.

## Development

Run `npm test` for the editor workflow check. It uses your installed Trouble.nvim and a stubbed T3 connection.

`npm run check:live` checks authentication and project/thread discovery against the running app. It reads only; it never creates a thread or sends a message.

## License

[MIT](LICENSE) © 2026 LosFarmosCTL
