local hn = require("rex-nvim")
local comments = require("rex-nvim.comments")

T.test("init: setup creates guarded keymaps", function()
  vim.g.mapleader = " "
  vim.keymap.set("n", " ac", "<cmd>echo 'user owns this'<cr>") -- simulate user mapping
  hn.setup({})
  T.ok(vim.fn.maparg(" ac", "n"):match("user owns this"), "must not clobber user map")
  T.ok(vim.fn.maparg(" al", "n") ~= "", "free lhs must be mapped")
  vim.keymap.del("n", " ac")
end)

-- Issue #49: the sidebar daemon calls setup() again after the user's config
-- already did; the second call must not warn about the plugin's own keymaps.
T.test("init: calling setup() again does not warn about its own keymaps", function()
  local saved_config, orig_notify = vim.deepcopy(hn.config), vim.notify
  vim.g.mapleader = " "
  local warns = {}
  vim.notify = function(msg, level) if level == vim.log.levels.WARN then table.insert(warns, msg) end end
  hn.setup({ prefix = "<leader>h" }) -- the user's config (e.g. lazy.nvim opts)
  hn.setup() -- the sidebar daemon's VimEnter setup()
  vim.notify = orig_notify
  hn.config = saved_config
  T.eq(warns, {})
  T.eq(vim.fn.maparg(" hl", "n", false, true).desc, "rex-nvim: list comments")
  T.eq(vim.fn.maparg(" hc", "x", false, true).desc, "rex-nvim: comment selection")
end)

T.test("init: calling setup() again keeps a map the user set after the first call", function()
  local saved_config, orig_notify = vim.deepcopy(hn.config), vim.notify
  vim.g.mapleader = " "
  hn.setup({ prefix = "<leader>u" })
  vim.keymap.set("n", " ul", "<cmd>echo 'user owns this'<cr>") -- user remaps after setup
  local warns = {}
  vim.notify = function(msg, level) if level == vim.log.levels.WARN then table.insert(warns, msg) end end
  hn.setup()
  vim.notify = orig_notify
  hn.config = saved_config
  T.ok(vim.fn.maparg(" ul", "n"):match("user owns this"), "must not clobber user map")
  T.eq(warns, { "rex-nvim: not overriding existing map <leader>ul" })
  vim.keymap.del("n", " ul")
end)

T.test("init: comment_line adds a decorated comment via stubbed input", function()
  comments.clear()
  local ui = require("rex-nvim.ui")
  local orig = ui.input_comment
  ui.input_comment = function(cb) cb("stub comment") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "one", "two" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  hn.comment_line()
  ui.input_comment = orig
  local l = comments.list()
  T.eq(#l, 1)
  T.eq({ l[1].start_line, l[1].text }, { 2, "stub comment" })
end)

T.test("init: comment_range keeps the public line-range API", function()
  comments.clear()
  local ui = require("rex-nvim.ui")
  local orig = ui.input_comment
  ui.input_comment = function(cb) cb("stub range") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "one", "two", "three", "four" })
  vim.api.nvim_set_current_buf(b)
  hn.comment_range(2, 3)
  ui.input_comment = orig
  local l = comments.list()
  T.eq(#l, 1)
  T.eq({ l[1].start_line, l[1].end_line, l[1].text }, { 2, 3, "stub range" })
  T.eq(l[1].cols, nil)
  T.eq(comments.snippet(l[1].id), { "two", "three" })
end)

T.test("init: comment_selection uses the visual marks", function()
  comments.clear()
  local ui = require("rex-nvim.ui")
  local orig = ui.input_comment
  ui.input_comment = function(cb) cb("stub sel") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c", "d" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_mark(b, "<", 2, 0, {})
  vim.api.nvim_buf_set_mark(b, ">", 4, 0, {})
  hn.comment_selection()
  ui.input_comment = orig
  local list = comments.list()
  T.eq({ list[1].start_line, list[1].end_line }, { 2, 4 })
end)

T.test("init: comment_selection normalizes reversed marks", function()
  comments.clear()
  local ui = require("rex-nvim.ui")
  local orig = ui.input_comment
  ui.input_comment = function(cb) cb("stub sel") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c", "d" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_mark(b, "<", 4, 0, {})
  vim.api.nvim_buf_set_mark(b, ">", 2, 0, {})
  hn.comment_selection()
  ui.input_comment = orig
  local list = comments.list()
  T.eq({ list[1].start_line, list[1].end_line }, { 2, 4 })
end)

T.test("init: edit_comment updates text and refreshes its callout", function()
  comments.clear()
  local ui = require("rex-nvim.ui")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  local id = comments.add(b, { start_line = 1, end_line = 1 }, "old text")
  ui.decorate(id)
  local c = comments.get(id)

  local original_input = vim.ui.input
  vim.ui.input = function(_, cb) cb("new text") end
  hn.edit_comment(c)
  vim.ui.input = original_input

  T.eq(comments.get(id).text, "new text")
  local marks = vim.api.nvim_buf_get_extmarks(b, comments.ns, 0, -1, { details = true })
  local callout_text
  for _, mark in ipairs(marks) do
    if mark[4].virt_lines then callout_text = mark[4].virt_lines[1][2][1] end
  end
  T.ok(callout_text and callout_text:find("new text", 1, true), "callout shows edited text")
end)

T.test("init: git context returns nil when git cannot spawn", function()
  local original = vim.system
  vim.system = function() error("ENOENT: git") end
  local ok, context = pcall(hn._git_context)
  vim.system = original
  T.ok(ok)
  T.eq(context, nil)
end)

T.test("init: send_all formats, dispatches, clears", function()
  comments.clear()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  vim.api.nvim_buf_set_name(b, "/tmp/hn-send.lua")
  comments.add(b, { start_line = 1, end_line = 1 }, "check this")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local sent = {}
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  ui.pick_agent = function(_, cb) cb({ block_id = "wZ:p9", title = "π", status = "idle" }) end
  dispatch.send = function(block, text, opts) sent = { block, text, opts }; return true end
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":h")
  agents.list = function() return { { block_id = "wZ:p9", title = "π", status = "idle", cwd = dir } } end

  hn.send_all({ submit = false })
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.eq(sent[1], "wZ:p9")
  T.ok(sent[2]:find("1. hn-send.lua:1\n", 1, true), "path shortened against the agent's cwd")
  T.ok(sent[2]:find("> alpha", 1, true))
  T.eq(sent[3].submit, false)
  T.eq(comments.list(), {}, "clear_after_send default clears comments")
end)

T.test("init: send_all warns once when the resolved agent is working", function()
  comments.clear()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  vim.api.nvim_buf_set_name(b, "/tmp/hn-send-working.lua")
  comments.add(b, { start_line = 1, end_line = 1 }, "check this")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local warns = {}
  local o1, o2, o3, on = ui.pick_agent, dispatch.send, agents.list, vim.notify
  ui.pick_agent = function() error("picker must not open for a lone agent") end
  dispatch.send = function() return true end
  agents.list = function() return { { block_id = "wZ:p9", window_id = "wZ:t1", kind = "pi", title = "pi", status = "working", cwd = "/x/y/z" } } end
  vim.notify = function(msg, level) if level == vim.log.levels.WARN then table.insert(warns, msg) end end

  hn.send_all({ submit = true })
  ui.pick_agent, dispatch.send, agents.list, vim.notify = o1, o2, o3, on

  T.eq(#warns, 1, "working warning must fire exactly once")
  T.ok(warns[1]:find("is working", 1, true), "warning names the working state")
end)

T.test("init: send_all shows the picker when agents are ambiguous", function()
  comments.clear()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  vim.api.nvim_buf_set_name(b, "/tmp/hn-send-multi.lua")
  comments.add(b, { start_line = 1, end_line = 1 }, "check this")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local picked, sent = false, {}
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  ui.pick_agent = function(l, cb) picked = true; cb(l[1]) end
  dispatch.send = function(block) sent = { block }; return true end
  agents.list = function()
    return {
      { block_id = "wA:p1", window_id = "wA:t1", title = "pi", status = "idle" },
      { block_id = "wB:p2", window_id = "wB:t1", title = "claude", status = "idle" },
    }
  end

  hn.send_all({ submit = false })
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.ok(picked, "picker must open when the target is ambiguous")
  T.eq(sent[1], "wA:p1")
end)

T.test("init: send_all skips the picker for a lone agent", function()
  comments.clear()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  vim.api.nvim_buf_set_name(b, "/tmp/hn-send-solo.lua")
  comments.add(b, { start_line = 1, end_line = 1 }, "check this")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local picked, sent = false, {}
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  ui.pick_agent = function() picked = true end
  dispatch.send = function(block) sent = { block }; return true end
  agents.list = function() return { { block_id = "wZ:p9", window_id = "wZ:t1", title = "pi", status = "idle" } } end

  hn.send_all({ submit = false })
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.ok(not picked, "picker must not open for a single unambiguous agent")
  T.eq(sent[1], "wZ:p9")
end)

T.test("init: send_all retains comments when dispatch.send fails", function()
  comments.clear()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  vim.api.nvim_buf_set_name(b, "/tmp/hn-send-fail.lua")
  comments.add(b, { start_line = 1, end_line = 1 }, "check this")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  ui.pick_agent = function(_, cb) cb({ block_id = "wZ:p9", title = "π", status = "idle" }) end
  dispatch.send = function() return false, "boom" end
  agents.list = function() return { { block_id = "wZ:p9", title = "π", status = "idle" } } end

  hn.send_all({ submit = false })
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.eq(#comments.list(), 1, "comments must be retained after a failed send")
end)

T.test("init: statusline reflects pending comment count", function()
  comments.clear()
  T.eq(hn.statusline(), "")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x" })
  comments.add(b, { start_line = 1, end_line = 1 }, "a")
  comments.add(b, { start_line = 1, end_line = 1 }, "b")
  T.eq(hn.statusline(), "● 2")
end)

T.test("init: ref_range sends a bare citation, never submits, keeps comments", function()
  comments.clear()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c", "d" })
  vim.api.nvim_buf_set_name(b, "/repo/lua/hn-ref.lua")
  vim.api.nvim_set_current_buf(b)
  comments.add(b, { start_line = 1, end_line = 1 }, "keep me")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local sent = {}
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  ui.pick_agent = function() error("picker must not open for a lone agent") end
  dispatch.send = function(block, text, opts) sent = { block, text, opts }; return true end
  agents.list = function() return { { block_id = "wZ:p9", title = "pi", status = "idle", cwd = "/repo" } } end

  hn.ref_range(2, 3)
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.eq(sent[1], "wZ:p9")
  T.eq(sent[2], "lua/hn-ref.lua:2-3 ", "payload is the citation alone")
  T.eq(sent[3].submit, false, "a ref must never submit")
  T.eq(#comments.list(), 1, "referencing must not clear pending comments")
end)

T.test("init: ref_range shortens against the picked agent's cwd, not the buffer's", function()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a" })
  vim.api.nvim_buf_set_name(b, "/repo/deep/x.lua")
  vim.api.nvim_set_current_buf(b)

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local sent = {}
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  -- Two agents → the picker runs, so the cwd is only known after resolution.
  ui.pick_agent = function(l, cb) cb(l[2]) end
  dispatch.send = function(_, text) sent = { text }; return true end
  agents.list = function()
    return {
      { block_id = "wA:p1", window_id = "wA:t1", title = "pi", status = "idle", cwd = "/repo" },
      { block_id = "wB:p2", window_id = "wB:t1", title = "claude", status = "idle", cwd = "/repo/deep" },
    }
  end

  hn.ref_range(1, 1)
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.eq(sent[1], "x.lua:1 ", "path is relative to the agent that was picked")
end)

T.test("init: ref_range warns on an unsaved buffer but still sends", function()
  -- A listed, non-scratch buffer: 'modified' is ignored on buftype=nofile, so
  -- the scratch buffers the other tests use can never be dirty.
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b, "/repo/dirty.lua")
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "edited" })
  T.ok(vim.bo[b].modified, "precondition: the buffer is dirty")

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local warns, sent = {}, {}
  local o1, o2, o3, on = ui.pick_agent, dispatch.send, agents.list, vim.notify
  ui.pick_agent = function() end
  dispatch.send = function(_, text) sent = { text }; return true end
  agents.list = function() return { { block_id = "wZ:p9", title = "pi", status = "idle", cwd = "/repo" } } end
  vim.notify = function(msg, level) if level == vim.log.levels.WARN then table.insert(warns, msg) end end

  hn.ref_range(1, 1)
  ui.pick_agent, dispatch.send, agents.list, vim.notify = o1, o2, o3, on

  T.eq(#warns, 1, "unsaved buffer warns exactly once")
  T.ok(warns[1]:find("unsaved changes", 1, true))
  T.eq(sent[1], "dirty.lua:1 ", "the warning must not block the send")
  vim.bo[b].modified = false -- let the buffer be wiped without an E37 prompt
end)

T.test("init: ref_range refuses a buffer with no file", function()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a" })
  vim.api.nvim_set_current_buf(b)
  local dispatch = require("rex-nvim.dispatch")
  local warns = {}
  local o1, on = dispatch.send, vim.notify
  dispatch.send = function() error("must not dispatch a nameless buffer") end
  vim.notify = function(msg, level) if level == vim.log.levels.WARN then table.insert(warns, msg) end end

  hn.ref_range(1, 1)
  dispatch.send, vim.notify = o1, on

  T.eq(#warns, 1)
  T.ok(warns[1]:find("no file", 1, true))
end)

T.test("init: ref_line and ref_selection resolve their own span", function()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c", "d" })
  vim.api.nvim_buf_set_name(b, "/repo/span.lua")
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  local ui = require("rex-nvim.ui")
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local sent = {}
  local o1, o2, o3 = ui.pick_agent, dispatch.send, agents.list
  ui.pick_agent = function() end
  dispatch.send = function(_, text) sent[#sent + 1] = text; return true end
  agents.list = function() return { { block_id = "wZ:p9", title = "pi", status = "idle", cwd = "/repo" } } end

  hn.ref_line()
  vim.api.nvim_buf_set_mark(b, "<", 2, 0, {})
  vim.api.nvim_buf_set_mark(b, ">", 4, 0, {})
  hn.ref_selection()
  ui.pick_agent, dispatch.send, agents.list = o1, o2, o3

  T.eq(sent[1], "span.lua:3 ", "ref_line targets the cursor line")
  T.eq(sent[2], "span.lua:2-4 ", "ref_selection targets the visual marks")
end)

-- Runs `fn` with agents.list returning `list`, spawn.start answering with
-- `spawned`, and dispatch.send recording. Returns what was sent and spawned.
local function with_agents(list, spawned, fn)
  local dispatch = require("rex-nvim.dispatch")
  local agents = require("rex-nvim.agents")
  local spawn = require("rex-nvim.spawn")
  local ui = require("rex-nvim.ui")
  local rec = {}
  local saved = { dispatch.send, agents.list, spawn.start, ui.pick_agent, vim.deepcopy(hn.config), dispatch.focus }
  dispatch.focus = function(block) rec.focused = block; return true end
  dispatch.send = function(block, _, opts) rec.sent, rec.opts = block, opts; return true end
  agents.list = function() rec.listed = true; return vim.deepcopy(list) end
  spawn.start = function(spec, cb) rec.spec = spec; cb(spawned) end
  ui.pick_agent = function(l) rec.picker = l end
  local ok, err = pcall(fn, rec)
  dispatch.send, agents.list, spawn.start, ui.pick_agent, hn.config, dispatch.focus = unpack(saved)
  if not ok then error(err, 0) end
  return rec
end

local function one_comment(name)
  comments.clear()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha" })
  vim.api.nvim_buf_set_name(b, name)
  vim.api.nvim_set_current_buf(b)
  comments.add(b, { start_line = 1, end_line = 1 }, "check this")
end

local fresh = { block_id = "b:new", title = "claude", program = "claude", status = "idle", cwd = "/tmp" }

T.test("init: spawns the preferred agent when none is found", function()
  one_comment("/tmp/hn-spawn-1.lua")
  local rec = with_agents({}, fresh, function()
    hn.config.preferred_agent = { cmd = "claude" }
    hn.send_all({ submit = false })
  end)
  T.eq(rec.spec, { cmd = "claude" })
  T.eq(rec.sent, "b:new")
  T.eq(rec.opts.submit, false, "submit stays off unless preferred_agent.submit")
end)

T.test("init: preferred_agent.submit submits the message that spawned it", function()
  one_comment("/tmp/hn-spawn-2.lua")
  local rec = with_agents({}, fresh, function()
    hn.config.preferred_agent = { cmd = "claude", submit = true }
    hn.send_all({ submit = false })
  end)
  T.eq(rec.opts.submit, true)
end)

T.test("init: a reference to a spawned agent is never submitted", function()
  one_comment("/tmp/hn-spawn-3.lua")
  local rec = with_agents({}, fresh, function()
    hn.config.preferred_agent = { cmd = "claude", submit = true }
    hn.ref_range(1, 1)
  end)
  T.eq(rec.sent, "b:new")
  T.eq(rec.opts.submit, false)
end)

T.test("init: agent_scope = tab ignores agents in other tabs and spawns", function()
  one_comment("/tmp/hn-spawn-4.lua")
  local rec = with_agents({ { block_id = "b:other", program = "claude", same_window = false } }, fresh, function()
    hn.config.agent_scope = "tab"
    hn.config.preferred_agent = "claude"
    hn.send_all({ submit = false })
  end)
  T.eq(rec.sent, "b:new")
end)

T.test("init: agent_scope = session uses an agent in another tab", function()
  one_comment("/tmp/hn-spawn-5.lua")
  local rec = with_agents({ { block_id = "b:other", program = "claude", same_window = false } }, fresh, function()
    hn.config.preferred_agent = "claude"
    hn.send_all({ submit = false })
  end)
  T.eq(rec.spec, nil)
  T.eq(rec.sent, "b:other")
end)

T.test("init: preferred_agent picks its program among several agents", function()
  one_comment("/tmp/hn-spawn-6.lua")
  local rec = with_agents({
    { block_id = "b:pi", program = "pi", kind = "pi" },
    { block_id = "b:claude", program = "claude", kind = "claude-code" },
  }, fresh, function()
    hn.config.preferred_agent = { cmd = "claude" }
    hn.send_all({ submit = false })
  end)
  T.eq(rec.picker, nil)
  T.eq(rec.sent, "b:claude")
end)

T.test("init: without preferred_agent an empty session never spawns", function()
  local rec = with_agents({}, fresh, function()
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, "/tmp/hn-no-spawn.lua")
    vim.api.nvim_set_current_buf(b)
    hn.ref_range(1, 1)
  end)
  T.ok(rec.listed, "reached agent lookup")
  T.eq(rec.spec, nil)
end)

T.test("init: focus_agent focuses the agent after a send", function()
  one_comment("/tmp/hn-focus-1.lua")
  local rec = with_agents({ { block_id = "b:claude", program = "claude" } }, fresh, function()
    hn.config.focus_agent = true
    hn.send_all({ submit = false })
  end)
  T.eq(rec.focused, "b:claude")
end)

T.test("init: focus_agent focuses a freshly spawned agent", function()
  one_comment("/tmp/hn-focus-2.lua")
  local rec = with_agents({}, fresh, function()
    hn.config.focus_agent = true
    hn.config.preferred_agent = "claude"
    hn.send_all({ submit = false })
  end)
  T.eq(rec.focused, "b:new")
end)

T.test("init: focus stays in nvim by default", function()
  one_comment("/tmp/hn-focus-3.lua")
  local rec = with_agents({ { block_id = "b:claude", program = "claude" } }, fresh, function()
    hn.send_all({ submit = false })
  end)
  T.eq(rec.focused, nil)
end)

T.test("init: a failed send does not move focus", function()
  one_comment("/tmp/hn-focus-4.lua")
  local dispatch = require("rex-nvim.dispatch")
  local rec = with_agents({ { block_id = "b:claude", program = "claude" } }, fresh, function()
    hn.config.focus_agent = true
    dispatch.send = function() return false, "boom" end
    local on = vim.notify
    vim.notify = function() end
    hn.send_all({ submit = false })
    vim.notify = on
  end)
  T.eq(rec.focused, nil)
end)
