local M = {}

-- A paste event: Rex wraps it in bracketed-paste markers when the program
-- asked for them, which keeps a multi-line payload in the agent's input box
-- instead of submitting it line by line.
local ENTER = { key = "enter", mods = "", consumed_mods = "", text = "\r", unshifted_codepoint = 13, composing = false, action = "press" }

function M.send(block_id, text, opts, rpc)
  opts = opts or {}
  rpc = rpc or require("rex-nvim.rpc")
  local session = vim.env.REX_SESSION
  local function event(type, payload)
    return rpc.call(session, "block.event", { session_id = session, block_id = block_id, event = { type = type, payload = payload } })
  end
  local ok, err = event("paste", { text = text })
  if not ok then return false, "paste failed: " .. err end
  if opts.submit then
    ok, err = event("key", ENTER)
    if not ok then return false, "enter failed: " .. err end
  end
  return true
end

-- Moves Rex's focus to the agent's pane (split or floating).
function M.focus(block_id, rpc)
  rpc = rpc or require("rex-nvim.rpc")
  local session = vim.env.REX_SESSION
  local ok, err = rpc.call(session, "session.focus_block", { session_id = session, block_id = block_id })
  if not ok then return false, "focus failed: " .. err end
  return true
end

return M
