local M = {}

local function raw_exec(argv)
  local r = vim.system(argv, { text = true }):wait()
  return { code = r.code, stdout = r.stdout or "", stderr = r.stderr or "" }
end

function M.default_exec(argv)
  return require("rex-nvim.debug").wrap_exec(raw_exec)(argv)
end

return M
