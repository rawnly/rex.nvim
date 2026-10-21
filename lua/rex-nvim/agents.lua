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
      local fg = (call(exec, b.block_id, "process") or {}).foreground or {}
      local status = root_status(call(exec, b.block_id, "program_status"), fg)
      local name = program_name(fg)
      if status or vim.list_contains(M.known, name) then
        local kind = status and status.effective_app or name
        table.insert(out, {
          block_id = b.block_id,
          window_id = b.window_id,
          same_window = here_window ~= nil and b.window_id == here_window,
          kind = kind ~= "" and kind or "unknown",
          status = status and status.state or "unknown",
          cwd = fg.cwd or "",
          title = b.label and b.label ~= "" and b.label ~= "shell" and b.label or kind,
        })
      end
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

-- Normalize the `preferred_agent` option: a command string ("claude") or a
-- table { cmd = "claude", split = "right", ratio = 50 }.
function M.normalize_preferred(opt)
  if type(opt) == "string" and opt ~= "" then opt = { cmd = opt } end
  if type(opt) ~= "table" or type(opt.cmd) ~= "string" or opt.cmd == "" then return nil end
  return { cmd = opt.cmd, split = opt.split or "right", ratio = opt.ratio or 50 }
end

-- Open `preferred.cmd` in a new, unfocused split beside this nvim's block (so
-- it lands in the same tab). Returns the new block id.
function M.spawn(preferred, exec)
  exec = exec or exec_mod.default_exec
  local here = vim.env.REX_BLOCK
  if not here or here == "" then
    return nil, "not running inside a Rex block (REX_BLOCK is unset)"
  end
  local argv = {
    "rex", "split", "-b", here, "--split", preferred.split, "--ratio", tostring(preferred.ratio),
    "--focus=false", "--json", "--label", preferred.cmd, "-c", vim.fn.getcwd(), "--",
    unpack(vim.split(preferred.cmd, "%s+", { trimempty = true })),
  }
  require("rex-nvim.debug").log("spawn: rex split %s", preferred.cmd)
  local r = exec(argv)
  if r.code ~= 0 then return nil, failure("rex split", r) end
  local ok, decoded = pcall(vim.json.decode, r.stdout)
  local id = ok and type(decoded) == "table" and decoded.block_ids and decoded.block_ids[1]
  if not id then return nil, "rex split: unparseable JSON" end
  -- A custom command isn't in `known`; make sure we can recognise it.
  local name = vim.fs.basename(vim.split(preferred.cmd, "%s+", { trimempty = true })[1])
  if not vim.list_contains(M.known, name) then table.insert(M.known, name) end
  return id
end

-- Poll until `block_id` shows up as an agent, then until its screen has been
-- drawn and stopped changing (the TUI is up and its input box can take a
-- paste), then call cb(agent). On timeout call cb(nil, err). Non-blocking.
-- Detection alone isn't enough: the process is the foreground program well
-- before it has rendered, and anything pasted that early is lost.
function M.await(block_id, opts, cb, exec)
  exec = exec or exec_mod.default_exec
  opts = vim.tbl_extend("force", {
    timeout_ms = 20000, interval_ms = 250, settle_ms = 500, stable_polls = 3,
  }, opts or {})
  local dbg = require("rex-nvim.debug")
  local waited, polls = 0, 0
  local found, last, stable = nil, nil, 0

  local function tick(fn)
    if waited >= opts.timeout_ms then
      dbg.log("await: timed out after %d polls (%s)", polls, found and "screen never settled" or "agent never detected")
      cb(nil, found and "timed out waiting for the agent to finish starting"
        or "timed out waiting for the agent to start")
      return
    end
    waited = waited + opts.interval_ms
    vim.defer_fn(fn, opts.interval_ms)
  end

  local function poll()
    polls = polls + 1
    if not found then
      local list = M.list(exec)
      dbg.log("await poll #%d: %d agent(s) listed, waiting for %s", polls, list and #list or 0, block_id)
      for _, a in ipairs(list or {}) do
        if a.block_id == block_id then
          found = a
          dbg.log("await: agent detected (kind=%s status=%s); waiting for screen to settle", a.kind, a.status)
        end
      end
      if not found then return tick(poll) end
    end
    local r = exec({ "rex", "capture", "-b", block_id, "--trim" })
    local screen = r.code == 0 and vim.trim(r.stdout) or ""
    if screen ~= "" and screen == last then
      stable = stable + 1
    else
      stable = 0
    end
    last = screen
    dbg.log("await poll #%d: screen %d bytes, stable %d/%d", polls, #screen, stable, opts.stable_polls)
    if stable >= opts.stable_polls then
      dbg.log("await: screen settled, sending after %dms", opts.settle_ms)
      vim.defer_fn(function() cb(found) end, opts.settle_ms)
      return
    end
    tick(poll)
  end
  poll()
end

function M.display(agent)
  local tail = vim.fn.fnamemodify(agent.cwd, ":t")
  return string.format("%s · %s · %s", agent.kind, agent.status, tail)
end

return M
