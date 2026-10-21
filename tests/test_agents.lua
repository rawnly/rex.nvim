local agents = require("rex-nvim.agents")

local blocks = vim.json.encode({ blocks = {
  { block_id = "b:self", window_id = "w:1", label = "shell" },
  { block_id = "b:pi", window_id = "w:1", label = "shell" },
  { block_id = "b:claude", window_id = "w:2", label = "review" },
  { block_id = "b:zsh", window_id = "w:2", label = "shell" },
} })

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

local function fake_exec(code)
  return function(argv)
    if code then return { code = code, stdout = "", stderr = "boom" } end
    if argv[3] == "ls" then return { code = 0, stdout = blocks, stderr = "" } end
    local resp = responses[argv[5] .. " " .. argv[6]]
    return { code = resp and 0 or 1, stdout = resp and vim.json.encode(resp) or "", stderr = "" }
  end
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
    local list, err = agents.list(fake_exec())
    T.eq(err, nil)
    T.eq(#list, 2)
    -- sorted by title: "pi" < "review"
    T.eq(list[1], { block_id = "b:pi", window_id = "w:1", same_window = true,
      kind = "pi", status = "unknown", cwd = "/tmp/proj-a", title = "pi" })
    T.eq(list[2], { block_id = "b:claude", window_id = "w:2", same_window = false,
      kind = "claude-code", status = "working", cwd = "/tmp/proj-b", title = "review" })
  end)
end)

T.test("agents: ignores a status left behind by an earlier program", function()
  with_env({ REX_SESSION = "s:1", REX_BLOCK = "b:self" }, function()
    for _, a in ipairs(agents.list(fake_exec())) do
      T.ok(a.block_id ~= "b:zsh")
    end
  end)
end)

T.test("agents: outside a Rex session returns err", function()
  with_env({ REX_SESSION = "" }, function()
    local list, err = agents.list(fake_exec())
    T.eq(list, nil)
    T.ok(err and err:match("REX_SESSION"))
  end)
end)

T.test("agents: CLI failure returns err", function()
  with_env({ REX_SESSION = "s:1" }, function()
    local list, err = agents.list(fake_exec(1))
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

T.test("agents: normalize_preferred accepts a string or table", function()
  T.eq(agents.normalize_preferred("claude"), { cmd = "claude", split = "right", ratio = 50 })
  T.eq(agents.normalize_preferred({ cmd = "pi", split = "below", ratio = 30 }),
    { cmd = "pi", split = "below", ratio = 30 })
  T.eq(agents.normalize_preferred(nil), nil)
  T.eq(agents.normalize_preferred(""), nil)
end)

T.test("agents: spawn splits beside our block unfocused and returns the new id", function()
  local saved = vim.env.REX_BLOCK
  vim.env.REX_BLOCK = "block:me"
  local seen
  local id = agents.spawn({ cmd = "claude --foo", split = "right", ratio = 50 }, function(argv)
    seen = argv
    return { code = 0, stdout = vim.json.encode({ block_ids = { "block:new" } }), stderr = "" }
  end)
  vim.env.REX_BLOCK = saved
  T.eq(id, "block:new")
  T.eq(seen[2], "split")
  T.ok(vim.list_contains(seen, "--focus=false"), "must not steal focus")
  T.eq(seen[#seen - 1], "claude")
  T.eq(seen[#seen], "--foo")
  T.eq(seen[4], "block:me")
end)

T.test("agents: spawn reports a failing rex split", function()
  local saved = vim.env.REX_BLOCK
  vim.env.REX_BLOCK = "block:me"
  local id, err = agents.spawn({ cmd = "claude", split = "right", ratio = 50 },
    function() return { code = 1, stdout = "", stderr = "boom" } end)
  vim.env.REX_BLOCK = saved
  T.eq(id, nil)
  T.ok(err:match("boom"), err)
end)
