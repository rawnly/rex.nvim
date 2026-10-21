-- Timing/debug log. Off by default; toggle with `:Rex debug on|off`, view with
-- `:Rex debug log`, or set `debug = true` in setup(). Entries are kept in
-- memory (ring buffer) so enabling it costs nothing when off.
local M = {}

local MAX = 500
local hrtime = vim.uv.hrtime

M.enabled = false
local entries = {}
local t0 = nil

function M.set(on)
  M.enabled = on and true or false
end

-- Start a new "trace" (one user action); times are logged relative to it.
function M.begin(label)
  if not M.enabled then return end
  t0 = hrtime()
  M.log("── " .. label)
end

function M.log(msg, ...)
  if not M.enabled then return end
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  -- One entry = one line; payloads in argv are multi-line and can be huge.
  msg = msg:gsub("\r?\n", "⏎")
  if #msg > 300 then msg = msg:sub(1, 300) .. "…" end
  local now = hrtime()
  local since = t0 and (now - t0) / 1e6 or 0
  table.insert(entries, string.format("%s  +%7.1fms  %s", os.date("%H:%M:%S"), since, msg))
  if #entries > MAX then table.remove(entries, 1) end
end

-- Wrap an exec function so every `rex` call logs its argv and duration.
function M.wrap_exec(exec)
  return function(argv)
    if not M.enabled then return exec(argv) end
    local s = hrtime()
    local r = exec(argv)
    M.log("exec %s → code %s in %.1fms", table.concat(argv, " "), tostring(r.code), (hrtime() - s) / 1e6)
    return r
  end
end

function M.clear()
  entries = {}
  t0 = nil
end

function M.entries()
  return entries
end

-- Open the log in a scratch split.
function M.show()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = #entries > 0 and entries
    or { "(empty — enable with `:Rex debug on`, then repeat the action)" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "rex-nvim-log"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
end

return M
