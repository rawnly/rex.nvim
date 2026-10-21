local M = {}
local exec_mod = require("rex-nvim.exec")

-- Bracketed paste keeps a multi-line payload in the agent's input box instead
-- of submitting it line by line.
local function paste(text)
  return "\27[200~" .. text .. "\27[201~"
end

function M.send(block_id, text, opts, exec)
  opts = opts or {}
  exec = exec or exec_mod.default_exec
  local r = exec({ "rex", "send", "-b", block_id, paste(text) })
  if r.code ~= 0 then
    return false, "rex send failed: " .. (r.stderr ~= "" and vim.trim(r.stderr) or ("exit " .. r.code))
  end
  if opts.submit then
    r = exec({ "rex", "send-key", "-b", block_id, "enter" })
    if r.code ~= 0 then
      return false, "rex send-key failed: " .. (r.stderr ~= "" and vim.trim(r.stderr) or ("exit " .. r.code))
    end
  end
  return true
end

return M
