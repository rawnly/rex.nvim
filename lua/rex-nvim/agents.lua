local M = {}
local exec_mod = require("rex-nvim.exec")

-- Foreground programs treated as agents even when they report no status of
-- their own. Anything that reports a status (OSC 7501) counts too.
M.known = { "claude", "codex", "pi", "opencode", "gemini", "aider", "amp", "cursor-agent", "crush", "goose", "qwen" }

local function failure(what, r)
  return what .. " failed: " .. (r.stderr ~= "" and vim.trim(r.stderr) or ("exit " .. r.code))
end

local function call(exec, block_id, method)
  local r = exec({ "rex", "block", "call", "-b", block_id, method })
  if r.code ~= 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, r.stdout)
  if ok and type(decoded) == "table" then return decoded end
end

-- The root status record (the one without an id) is the program's own status,
-- as long as it came from the program still in the foreground.
local function root_status(status, fg)
  for _, rec in ipairs((status or {}).records or {}) do
    if rec.id == nil and (not rec.owner or rec.owner.pid == fg.pid) then return rec end
  end
end

local function program_name(fg)
  local name = fg.argv0 or fg.name or ""
  return vim.fs.basename((name:gsub("^%-", "")))
end

local shells = { sh = true, bash = true, zsh = true, fish = true, dash = true, nu = true }
-- Launchers whose own name says nothing about the agent they run.
local wrappers = { npx = true, bunx = true, env = true, node = true, pnpm = true, yarn = true,
  uvx = true, sudo = true, python = true, python3 = true, deno = true, bun = true }

-- Describe one block as an agent, or nil. Returns (agent_or_nil, alive).
-- `force` accepts any non-shell foreground program (the block is known to be
-- the agent we spawned, whatever its process is called).
local function describe(exec, b, here_window, force)
  local proc = call(exec, b.block_id, "process")
  if not proc then return nil, false end
  local fg = proc.foreground or {}
  local status = root_status(call(exec, b.block_id, "program_status"), fg)
  local name = program_name(fg)
  local known = vim.list_contains(M.known, name)
  if not (status or known or (force and fg.pid and name ~= "" and not shells[name])) then
    return nil, true
  end
  local kind = status and status.effective_app or name
  return {
    block_id = b.block_id,
    window_id = b.window_id,
    same_window = here_window ~= nil and b.window_id == here_window,
    kind = kind ~= "" and kind or "unknown",
    status = status and status.state or "unknown",
    cwd = fg.cwd or "",
    title = b.label and b.label ~= "" and b.label ~= "shell" and b.label or kind,
  }, true
end

-- Agents in the current Rex session: every block other than our own whose
-- foreground program is a known agent or reports a status.
function M.list(exec)
  exec = exec or exec_mod.default_exec
  local session = vim.env.REX_SESSION
  if not session or session == "" then
    return nil, "not running inside a Rex session (REX_SESSION is unset)"
  end
  local r = exec({ "rex", "block", "ls", "-s", session, "--json" })
  if r.code ~= 0 then return nil, failure("rex block ls", r) end
  local ok, decoded = pcall(vim.json.decode, r.stdout)
  if not ok or type(decoded) ~= "table" then return nil, "rex block ls: unparseable JSON" end
  local here = vim.env.REX_BLOCK
  local here_window
  for _, b in ipairs(decoded.blocks or {}) do
    if b.block_id == here then here_window = b.window_id end
  end
  local out = {}
  for _, b in ipairs(decoded.blocks or {}) do
    if b.block_id ~= here then
      local agent = describe(exec, b, here_window)
      if agent then table.insert(out, agent) end
    end
  end
  table.sort(out, function(x, y) return x.title < y.title end)
  return out
end

-- Resolve the one agent to target without a picker, or nil when it's ambiguous.
-- `list` is already session-scoped by M.list. Narrowest unambiguous match wins:
--   1. a single agent in the same window (tab) as this nvim;
--   2. otherwise, a lone agent in the session.
-- Anything ambiguous (2+ candidates) returns nil so the caller shows the picker.
function M.resolve(list)
  if #list == 1 then return list[1] end
  local in_window = {}
  for _, a in ipairs(list) do
    if a.same_window then table.insert(in_window, a) end
  end
  if #in_window == 1 then return in_window[1] end
  return nil
end

-- Quote-aware split of a command line into argv.
local function split_args(str)
  local out, cur, q = {}, nil, nil
  for i = 1, #str do
    local ch = str:sub(i, i)
    if q then
      if ch == q then q = nil else cur = cur .. ch end
    elseif ch == '"' or ch == "'" then
      q = ch
      cur = cur or ""
    elseif ch:match("%s") then
      if cur then out[#out + 1] = cur; cur = nil end
    else
      cur = (cur or "") .. ch
    end
  end
  if cur then out[#out + 1] = cur end
  return out
end

-- Normalize the `preferred_agent` option: a command string ("claude"), an argv
-- list, or a table { cmd = "claude" | {argv...}, name = "claude", split = "right",
-- ratio = 50 }. `name` is the process name used to recognise the agent later.
function M.normalize_preferred(opt)
  if type(opt) == "string" or (type(opt) == "table" and opt[1] ~= nil) then opt = { cmd = opt } end
  if type(opt) ~= "table" then return nil end
  local argv
  if type(opt.cmd) == "string" then
    argv = split_args(opt.cmd)
  elseif type(opt.cmd) == "table" then
    argv = vim.tbl_filter(function(x) return type(x) == "string" and x ~= "" end, opt.cmd)
  end
  if not argv or #argv == 0 then return nil end
  return {
    cmd = table.concat(argv, " "),
    argv = argv,
    name = opt.name or vim.fs.basename(argv[1]),
    explicit_name = opt.name ~= nil,
    split = opt.split or "right",
    ratio = opt.ratio or 50,
  }
end

-- Make a configured agent recognisable by process name. Called from setup().
function M.register(preferred)
  if not preferred then return end
  if wrappers[preferred.name] and not preferred.explicit_name then return end
  if not vim.list_contains(M.known, preferred.name) then table.insert(M.known, preferred.name) end
end

-- Open the preferred agent in a new, unfocused split beside this nvim's block
-- (so it lands in the same tab). Returns the new block id.
function M.spawn(preferred, exec)
  exec = exec or exec_mod.default_exec
  local here = vim.env.REX_BLOCK
  if not here or here == "" then
    return nil, "not running inside a Rex block (REX_BLOCK is unset)"
  end
  local argv = {
    "rex", "split", "-b", here, "--split", preferred.split, "--ratio", tostring(preferred.ratio),
    "--focus=false", "--json", "--label", preferred.cmd, "-c", vim.fn.getcwd(), "--",
    unpack(preferred.argv),
  }
  require("rex-nvim.debug").log("spawn: rex split %s", preferred.cmd)
  local r = exec(argv)
  if r.code ~= 0 then return nil, failure("rex split", r) end
  local ok, decoded = pcall(vim.json.decode, r.stdout)
  local id = ok and type(decoded) == "table" and decoded.block_ids and decoded.block_ids[1]
  if not id then return nil, "rex split: unparseable JSON" end
  return id
end

-- Current screen of a block, trimmed ("" on failure).
function M.capture(block_id, exec)
  exec = exec or exec_mod.default_exec
  local r = exec({ "rex", "capture", "-b", block_id, "--trim" })
  return r.code == 0 and vim.trim(r.stdout) or ""
end

-- Poll only `block_id` until its program is up and its screen has been drawn
-- and stopped changing, then call cb(agent). On timeout, or if the pane closes
-- (the command failed to start), call cb(nil, err). The deadline is wall-clock.
-- Detection alone isn't enough: the process is the foreground program well
-- before it has rendered, and anything pasted that early is lost.
function M.await(block_id, opts, cb, exec)
  exec = exec or exec_mod.default_exec
  opts = vim.tbl_extend("force", {
    timeout_ms = 20000, interval_ms = 250, settle_ms = 500, stable_polls = 3,
  }, opts or {})
  local dbg = require("rex-nvim.debug")
  local deadline = vim.uv.now() + opts.timeout_ms
  local polls, dead = 0, 0
  local found, last, stable = nil, nil, 0

  local function again(fn)
    if vim.uv.now() >= deadline then
      dbg.log("await: timed out after %d polls", polls)
      cb(nil, found and "timed out waiting for the agent to finish starting"
        or "timed out waiting for the agent to start")
      return
    end
    vim.defer_fn(fn, opts.interval_ms)
  end

  local function poll()
    polls = polls + 1
    local agent, alive = describe(exec, { block_id = block_id }, nil, true)
    if not alive then
      dead = dead + 1
      if dead >= 3 then
        cb(nil, "the agent pane closed before it started (is the command valid?)")
        return
      end
      return again(poll)
    end
    dead = 0
    if agent then found = agent end
    if not found then return again(poll) end
    local screen = M.capture(block_id, exec)
    if screen ~= "" and screen == last then stable = stable + 1 else stable = 0 end
    last = screen
    dbg.log("await poll #%d: screen %d bytes, stable %d/%d", polls, #screen, stable, opts.stable_polls)
    if stable >= opts.stable_polls then
      vim.defer_fn(function() cb(found) end, opts.settle_ms)
      return
    end
    again(poll)
  end
  poll()
end

function M.display(agent)
  local tail = vim.fn.fnamemodify(agent.cwd, ":t")
  return string.format("%s · %s · %s", agent.kind, agent.status, tail)
end

return M
