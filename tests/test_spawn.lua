local spawn = require("rex-nvim.spawn")

-- Fake rpc: records every call, then answers modes/process from `script`, one
-- entry per poll: { paste = bool, exit = { exit_code, error }? }.
local function fake_rpc(script, split_err)
  local state = { polls = 0, calls = {} }
  state.rpc = {
    call = function(_, method, payload)
      if method == "block.method" then
        state.calls[payload.method] = payload
        if payload.method == "size" then return { columns = 100, rows = 50, cell_width_px = 8, cell_height_px = 16 } end
        return {}
      end
      state.calls[method] = payload
      if method == "session.new_split" then
        if split_err then return nil, split_err end
        return { block_ids = { "b:new" } }
      end
      return {}
    end,
    batch = function()
      state.polls = state.polls + 1
      local step = script[math.min(state.polls, #script)]
      return {
        { result = { modes = { { name = "bracketed_paste", set = step.paste or false } } } },
        { result = { last_exit = step.exit } },
      }
    end,
  }
  return state
end

local function run(spec, state)
  local got
  local saved = { spawn.poll_ms, vim.env.REX_SESSION, vim.env.REX_BLOCK }
  spawn.poll_ms, vim.env.REX_SESSION, vim.env.REX_BLOCK = 1, "s:1", "b:nvim"
  spawn.start(spec, function(agent, err) got = { agent = agent, err = err } end, state.rpc)
  vim.wait(1000, function() return got ~= nil end, 1)
  spawn.poll_ms, vim.env.REX_SESSION, vim.env.REX_BLOCK = unpack(saved)
  return got
end

T.test("spawn: normalize accepts a string, an argv list, or a table", function()
  T.eq(spawn.normalize("claude --resume").cmd, { "claude", "--resume" })
  T.eq(spawn.normalize({ "codex", "-a" }).cmd, { "codex", "-a" })
  T.eq(spawn.normalize({ cmd = "/opt/bin/claude", split = "below", ratio = 30, float = true, submit = true }),
    { cmd = { "/opt/bin/claude" }, name = "claude", split = "below", ratio = 30, float = true, submit = true })
  local d = spawn.normalize("pi")
  T.eq({ d.split, d.ratio, d.float, d.submit }, { "right", 50, false, false })
  T.ok(select(2, spawn.normalize({ cmd = "pi", split = "up" })))
  T.ok(select(2, spawn.normalize({ cmd = "pi", ratio = 0.3 * 1000 })))
  T.ok(select(2, spawn.normalize({ cmd = "" })))
end)

T.test("spawn: splits beside nvim, hands the pane to the app, waits for bracketed paste", function()
  local state = fake_rpc({ {}, {}, { paste = true } })
  local got = run({ cmd = "claude", split = "right", ratio = 40 }, state)
  T.eq(got.err, nil)
  T.eq(got.agent.block_id, "b:new")
  T.eq(got.agent.program, "claude")
  T.eq(state.polls, 3)
  local split = state.calls["session.new_split"]
  T.eq({ split.anchor_id, split.direction, split.side, split.focus }, { "b:nvim", "horizontal", "after", false })
  T.ok(math.abs(split.ratio - 0.6) < 1e-9, "new pane after nvim gets ratio%")
  T.eq(split.layout.block.options, { command = { "claude" }, cwd = vim.fn.getcwd() })
  T.eq(state.calls["session.disown_block"].block_ids, { "b:new" })
  T.eq(state.calls["session.float_block"], nil)
  T.eq(state.calls.size.block_id, "b:nvim")
  T.eq(state.calls.resize.block_id, "b:new")
  T.eq(state.calls.resize.args, { columns = 39, rows = 50, cell_width_px = 8, cell_height_px = 16 })
end)

T.test("spawn: estimate sizes splits and floats from nvim's pane", function()
  local me = { columns = 100, rows = 50 }
  T.eq(spawn.estimate(me, "right", 0.3, false), { columns = 29, rows = 50 })
  T.eq(spawn.estimate(me, "below", 0.3, false), { columns = 100, rows = 14 })
  T.eq(spawn.estimate(me, "left", 0.3, true), { columns = 30, rows = 50 })
  T.eq(spawn.estimate(nil, "right", 0.3, false), nil)
end)

T.test("spawn: float hugs the split edge", function()
  local cases = {
    right = { 0.7, 0, 0.3, 1 }, left = { 0, 0, 0.3, 1 },
    below = { 0, 0.7, 1, 0.3 }, above = { 0, 0, 1, 0.3 },
  }
  for split, want in pairs(cases) do
    local state = fake_rpc({ { paste = true } })
    run({ cmd = "pi", split = split, ratio = 30, float = true }, state)
    local got = state.calls["session.float_block"].bounds
    for i = 1, 4 do T.ok(math.abs(got[i] - want[i]) < 1e-9, split .. " bounds " .. vim.inspect(got)) end
  end
end)

T.test("spawn: reports an agent that exits before it is ready", function()
  local got = run("nope", fake_rpc({ { exit = { exit_code = 127, error = "exit status 127" } } }))
  T.eq(got.agent, nil)
  T.eq(got.err, "nope exited (exit status 127)")
end)

T.test("spawn: reports a failed split", function()
  local got = run("pi", fake_rpc({ {} }, "conflict"))
  T.eq(got.agent, nil)
  T.ok(got.err:match("could not start pi: conflict"))
end)

T.test("spawn: gives up after the timeout", function()
  local saved = spawn.timeout_ms
  spawn.timeout_ms = 20
  local got = run("pi", fake_rpc({ {} }))
  spawn.timeout_ms = saved
  T.eq(got.err, "pi did not become ready in time")
end)
