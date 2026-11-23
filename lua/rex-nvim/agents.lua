local M = {}

-- Foreground programs treated as agents even when they report no status of
-- their own. Anything that reports a status (OSC 7501) counts too.
M.known = { "claude", "codex", "pi", "opencode", "gemini", "aider", "amp", "cursor-agent", "crush", "goose", "qwen", "vibe" }

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
function M.list(rpc)
  rpc = rpc or require("rex-nvim.rpc")
  local session = vim.env.REX_SESSION
  if not session or session == "" then
    return nil, "not running inside a Rex session (REX_SESSION is unset)"
  end
  local listed, err = rpc.call(session, "session.list_blocks", { session_id = session }, { idempotent = true })
  if not listed then return nil, err end
  local here = vim.env.REX_BLOCK
  local here_window
  local others = {}
  for _, b in ipairs(listed.blocks or {}) do
    if b.block_id == here then here_window = b.window_id end
    if b.block_id ~= here then table.insert(others, b) end
  end
  -- Ask every block for its process and status in one round trip.
  local calls = {}
  for _, b in ipairs(others) do
    for _, method in ipairs({ "process", "program_status" }) do
      table.insert(calls, { "block.method", { session_id = session, block_id = b.block_id, method = method } })
    end
  end
  local answers = {}
  if #calls > 0 then
    answers, err = rpc.batch(session, calls, { idempotent = true })
    if not answers then return nil, err end
  end
  local out = {}
  for i, b in ipairs(others) do
    local fg = ((answers[2 * i - 1] or {}).result or {}).foreground or {}
    local status = root_status((answers[2 * i] or {}).result, fg)
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

function M.display(agent)
  local tail = vim.fn.fnamemodify(agent.cwd, ":t")
  return string.format("%s · %s · %s", agent.kind, agent.status, tail)
end

return M
