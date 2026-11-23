local agents = require("rex-nvim.agents")

local blocks = { blocks = {
  { block_id = "b:self", window_id = "w:1", label = "shell" },
  { block_id = "b:pi", window_id = "w:1", label = "shell" },
  { block_id = "b:claude", window_id = "w:2", label = "review" },
  { block_id = "b:zsh", window_id = "w:2", label = "shell" },
} }

local responses = {
  ["b:pi process"] = { foreground = { pid = 1, argv0 = "/usr/local/bin/pi", cwd = "/tmp/proj-a" } },
  ["b:pi program_status"] = { records = {} },
  ["b:claude process"] = { foreground = { pid = 2, argv0 = "claude", cwd = "/tmp/proj-b" } },
  ["b:claude program_status"] = { records = {
    { id = "sub", state = "idle" },
    { state = "working", effective_app = "claude-code", owner = { pid = 2 } },
  } },
  ["b:zsh process"] = { foreground = { pid = 3, argv0 = "-zsh", cwd = "/tmp" } },
  ["b:zsh program_status"] = { records = { { state = "working", app = "cargo", owner = { pid = 99 } } } },
}

-- A stand-in for rex-nvim.rpc: answers from `blocks` and `responses`, or fails
-- every call with `fail`.
local function fake_rpc(fail)
  local function answer(method, payload)
    if fail then return nil, fail end
    if method == "session.list_blocks" then return blocks end
    local resp = responses[payload.block_id .. " " .. payload.method]
    if resp then return resp end
    return nil, "method_not_found"
  end
  return {
    call = function(_, method, payload) return answer(method, payload) end,
    batch = function(_, calls)
      if fail then return nil, fail end
      local out = {}
      for i, c in ipairs(calls) do
        local r, e = answer(c[1], c[2])
        out[i] = { result = r, err = e }
      end
      return out
    end,
  }
end

local function with_env(env, fn)
  local saved = {}
  for k, v in pairs(env) do saved[k] = vim.env[k]; vim.env[k] = v end
  local ok, err = pcall(fn)
  for k in pairs(env) do vim.env[k] = saved[k] end
  if not ok then error(err, 0) end
end

T.test("agents: lists agent blocks in the session, skipping our own", function()
  with_env({ REX_SESSION = "s:1", REX_BLOCK = "b:self" }, function()
    local list, err = agents.list(fake_rpc())
    T.eq(err, nil)
    T.eq(#list, 2)
    -- sorted by title: "pi" < "review"
    T.eq(list[1], { block_id = "b:pi", window_id = "w:1", same_window = true,
      kind = "pi", program = "pi", status = "unknown", cwd = "/tmp/proj-a", title = "pi" })
    T.eq(list[2], { block_id = "b:claude", window_id = "w:2", same_window = false,
      kind = "claude-code", program = "claude", status = "working", cwd = "/tmp/proj-b", title = "review" })
  end)
end)

T.test("agents: ignores a status left behind by an earlier program", function()
  with_env({ REX_SESSION = "s:1", REX_BLOCK = "b:self" }, function()
    for _, a in ipairs(agents.list(fake_rpc())) do
      T.ok(a.block_id ~= "b:zsh")
    end
  end)
end)

T.test("agents: outside a Rex session returns err", function()
  with_env({ REX_SESSION = "" }, function()
    local list, err = agents.list(fake_rpc())
    T.eq(list, nil)
    T.ok(err and err:match("REX_SESSION"))
  end)
end)

T.test("agents: server failure returns err", function()
  with_env({ REX_SESSION = "s:1" }, function()
    local list, err = agents.list(fake_rpc("boom"))
    T.eq(list, nil)
    T.ok(err and err:match("boom"))
  end)
end)

T.test("agents: resolve returns the lone session agent", function()
  local a = agents.resolve({ { block_id = "b:1" } })
  T.eq(a.block_id, "b:1")
end)

T.test("agents: resolve picks the single agent in our window", function()
  local a = agents.resolve({
    { block_id = "b:1", same_window = false },
    { block_id = "b:2", same_window = true },
  })
  T.eq(a.block_id, "b:2")
end)

T.test("agents: resolve returns nil when our window is ambiguous", function()
  T.eq(agents.resolve({
    { block_id = "b:1", same_window = true },
    { block_id = "b:2", same_window = true },
  }), nil)
end)

T.test("agents: resolve returns nil when no window disambiguates", function()
  T.eq(agents.resolve({ { block_id = "b:1" }, { block_id = "b:2" } }), nil)
end)

T.test("agents: display row leads with agent kind", function()
  local row = agents.display({ kind = "pi", title = "π - a", status = "idle", cwd = "/x/y/proj" })
  T.eq(row, "pi · idle · proj")
end)

T.test("agents: resolve prefers the preferred program over the picker", function()
  local list = {
    { block_id = "b:1", program = "pi", kind = "pi" },
    { block_id = "b:2", program = "claude", kind = "claude-code" },
  }
  T.eq(agents.resolve(list, "claude").block_id, "b:2")
  T.eq(agents.resolve(list, "claude-code").block_id, "b:2")
  T.eq(agents.resolve(list, "codex"), nil, "no match falls back to the usual rules")
end)

T.test("agents: resolve narrows several preferred matches to nvim's tab", function()
  local list = {
    { block_id = "b:1", program = "claude", same_window = false },
    { block_id = "b:2", program = "claude", same_window = true },
    { block_id = "b:3", program = "pi", same_window = true },
  }
  T.eq(agents.resolve(list, "claude").block_id, "b:2")
end)

T.test("agents: in_tab keeps only agents in nvim's tab", function()
  local list = { { block_id = "b:1", same_window = true }, { block_id = "b:2", same_window = false } }
  T.eq(agents.in_tab(list), { { block_id = "b:1", same_window = true } })
end)
