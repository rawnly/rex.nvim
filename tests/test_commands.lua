local hn = require("rex-nvim")
local comments = require("rex-nvim.comments")
local commands = require("rex-nvim.commands")

local function clear_cmd()
  pcall(vim.api.nvim_del_user_command, "Rex")
end

T.test("commands: register creates :Rex and is idempotent", function()
  commands.register()
  T.eq(vim.fn.exists(":Rex"), 2)
  commands.register() -- must not error
  T.eq(vim.fn.exists(":Rex"), 2)
  local info = vim.api.nvim_get_commands({}).Rex
  T.eq(info.nargs, "?")
  T.ok(info.range, "command accepts a range")
end)

T.test("commands: register replaces a pre-existing placeholder", function()
  clear_cmd()
  vim.api.nvim_create_user_command("Rex", function() end, { nargs = "*" })
  commands.register()
  T.eq(vim.api.nvim_get_commands({}).Rex.nargs, "?")
end)

T.test("commands: complete filters subcommands by lead", function()
  T.eq(commands.complete("", "Rex "), { "comment", "list", "send", "submit", "ref" })
  T.eq(commands.complete("s", "Rex s"), { "send", "submit" })
  T.eq(commands.complete("r", "Rex r"), { "ref" })
  T.eq(commands.complete("c", "Rex c"), { "comment" })
  T.eq(commands.complete("co", "Rex co"), { "comment" })
  T.eq(commands.complete("x", "Rex x"), {})
end)

T.test("commands: complete honors a range and stops after a subcommand", function()
  T.eq(commands.complete("s", "'<,'>Rex s"), { "send", "submit" })
  T.eq(commands.complete("s", "5,10Rex s"), { "send", "submit" })
  T.eq(commands.complete("", "Rex send "), {})
end)

T.test("commands: run comment forwards the command range", function()
  local got
  local orig = hn.comment_range
  hn.comment_range = function(s, e) got = { s, e } end
  commands.run({ fargs = { "comment" }, line1 = 2, line2 = 4 })
  hn.comment_range = orig
  T.eq(got, { 2, 4 })
end)

-- Run `:{range}Rex comment` after a real visual selection made with `keys`;
-- returns the line range it passed to comment_range().
local function comment_after(keys, range)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "the quick brown fox", "jumps over" })
  vim.api.nvim_set_current_buf(b)
  vim.cmd("normal! gg0" .. keys .. "\27")
  commands.register()
  local got
  local orig = hn.comment_range
  hn.comment_range = function(s, e) got = { s, e } end
  vim.cmd(range .. "Rex comment")
  hn.comment_range = orig
  return got
end

T.test("commands: :Rex comment stays linewise for visual and explicit ranges", function()
  T.eq(comment_after("4lve", "'<,'>"), { 1, 1 }, "visual command range is linewise")
  T.eq(comment_after("4lve", "1,1"), { 1, 1 }, "explicit range after a visual selection stays whole-line")
  T.eq(comment_after("4lve", "2,2"), { 2, 2 }, "explicit range other than the selection")
  T.eq(comment_after("4lve", ""), { 1, 1 }, "no range")
  T.eq(comment_after("Vj", "'<,'>"), { 1, 2 }, "linewise selection")
end)

T.test("commands: run send/submit map to the send_all submit flag", function()
  local got
  local orig = hn.send_all
  hn.send_all = function(opts) got = opts end
  commands.run({ fargs = { "send" } })
  T.eq(got, { submit = false })
  commands.run({ fargs = { "submit" } })
  T.eq(got, { submit = true })
  hn.send_all = orig
end)

T.test("commands: run ref forwards the range", function()
  local got
  local orig = hn.ref_range
  hn.ref_range = function(s, e) got = { s, e } end
  commands.run({ fargs = { "ref" }, line1 = 4, line2 = 9 })
  hn.ref_range = orig
  T.eq(got, { 4, 9 })
end)

T.test("commands: run list maps to list_comments", function()
  local got
  local orig = hn.list_comments
  hn.list_comments = function() got = true end
  commands.run({ fargs = { "list" } })
  T.eq(got, true)
  hn.list_comments = orig
end)

T.test("commands: run notifies on missing or unknown subcommand", function()
  local orig = vim.notify
  local msgs = {}
  vim.notify = function(msg, level) msgs[#msgs + 1] = { msg, level } end
  commands.run({ fargs = {} })
  commands.run({ fargs = { "bogus" } })
  vim.notify = orig
  T.eq(#msgs, 2)
  T.eq(msgs[2][2], vim.log.levels.ERROR)
  T.ok(msgs[2][1]:find("unknown subcommand"))
end)

T.test("commands: :Rex comment annotates the cursor line", function()
  comments.clear()
  commands.register()
  local ui = require("rex-nvim.ui")
  local orig = ui.input_comment
  ui.input_comment = function(cb) cb("stub") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("Rex comment") -- no range → cursor line
  ui.input_comment = orig
  local list = comments.list()
  T.eq({ list[1].start_line, list[1].end_line }, { 2, 2 }, "default range is the cursor line")
end)

T.test("commands: :<range>Rex comment annotates the range", function()
  comments.clear()
  commands.register()
  local ui = require("rex-nvim.ui")
  local orig = ui.input_comment
  ui.input_comment = function(cb) cb("stub") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c", "d" })
  vim.api.nvim_set_current_buf(b)
  vim.cmd("1,3Rex comment")
  ui.input_comment = orig
  local list = comments.list()
  T.eq({ list[1].start_line, list[1].end_line }, { 1, 3 })
end)

T.test("commands: setup() ensures the command exists", function()
  clear_cmd()
  hn.setup({})
  T.eq(vim.fn.exists(":Rex"), 2)
end)
