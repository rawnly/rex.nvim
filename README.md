

https://github.com/user-attachments/assets/47bc945d-6377-4df5-80a6-93bd219fd1b6

# rex.nvim

Code-review comments in Neovim, sent to the coding agent running next to you
in Rex. Comment lines or a selection like a code review,
then paste them all into any agent in your Rex session (claude, codex, pi, …)
with file:line and git context.

## Features

- **Code annotations you send to the agent.** Comment lines or a selection
  like a code review. Then send them all to an agent in the session, with
  file:line and git context.
- **Inline file:line references.** Drop `path:12-20` into the agent's input
  mid-sentence.

## Requirements

nvim ≥ 0.10 · `rex` on PATH · nvim running inside a Rex session

## Install

With your plugin manager (e.g. lazy.nvim):

```lua
{ "rawnly/rex.nvim", opts = {} }
```

## Annotations

Each action has a default keymap and a `:Rex` subcommand (subcommands
tab-complete):

| Keymap | Command | Action |
| --- | --- | --- |
| `<leader>ac` | `:Rex comment` / `comment_selection()` | comment the current line / selection; visual `v` keymaps using `comment_selection()` send only that span (the command also takes whole-line ranges: `:5,10Rex comment`) |
| `<leader>al` | `:Rex list` | list comments (float): hover to jump, `⏎` edit, `d` delete |
| `<leader>as` | `:Rex send` | paste all comments into the agent's input |
| `<leader>aS` | `:Rex submit` | send all comments to the agent (auto-submits) |
| `<leader>ai` | `:Rex ref` | reference the current line / selection at the agent's cursor (also takes a range: `:5,10Rex ref`) |

Keymaps are on by default (prefix `<leader>a`) and never override a map you
already set. To bind your own, set `keymaps = false` and map the command:

```lua
require("rex-nvim").setup({ keymaps = false })
vim.keymap.set("n", "<leader>ac", "<CMD>Rex comment<CR>", { desc = "Comment" })
vim.keymap.set("x", "<leader>ac", function() require("rex-nvim").comment_selection() end, { desc = "Comment" })
```

Or call the Lua API directly (`comment_line`, `comment_selection`,
`comment_range(s, e)`, `list_comments`, `send_all{ submit = false|true }`,
`ref_line`, `ref_selection`, `ref_range(s, e)`).
See `:help rex-nvim` for the full reference.

## Finding the agent

Agents are the other panes in your Rex session whose foreground program is a
known agent (`claude`, `codex`, `pi`, `opencode`, …) or that report a status
to Rex. Sending skips the picker when the target is obvious: the lone agent in
the session, or the single agent in the same tab as nvim. The picker only
appears when two or more agents could plausibly be meant.

Text is pasted with `rex send` (as a bracketed paste, so multi-line prompts
stay in the input box); `submit` then presses Enter with `rex send-key`.

## References

`<leader>ai` (or `:Rex ref`) drops just `path:12-20` into the agent's input,
so you can mention code mid-sentence. It never submits.

Comments are ephemeral by design: in-memory only, extmark-tracked (they follow
your edits), cleared after a successful send. The sent prompt includes each
comment's file:line plus the repo and branch, so the agent has context.

For a pending-comment indicator (`● 3`) in your statusline:
`require("rex-nvim").statusline()`.

## Config

```lua
require("rex-nvim").setup({
  prefix = "<leader>a",     -- keymap prefix
  keymaps = true,           -- set false to define your own
  clear_after_send = true,  -- comments are ephemeral by design
})
```

## Tests

```sh
nvim --headless --noplugin -u NONE -l tests/run.lua
```
