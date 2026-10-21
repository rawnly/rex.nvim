-- :Rex user command with scoped subcommands (comment/list/send/submit/ref)
-- and completions. Private module; the public API lives in rex-nvim.init.
local M = {}

local subcommands = { "comment", "list", "send", "submit", "ref", "debug" }
local debug_actions = { "on", "off", "log", "clear" }

-- Idempotent: delete-then-create also replaces lazy.nvim's `cmd` placeholder.
function M.register()
  pcall(vim.api.nvim_del_user_command, "Rex")
  vim.api.nvim_create_user_command("Rex", function(opts)
    require("rex-nvim.commands").run(opts)
  end, {
    nargs = "*",
    range = true,
    desc = "rex-nvim: comment, list, send, or submit code annotations; reference a line range",
    complete = function(arg_lead, cmdline)
      return require("rex-nvim.commands").complete(arg_lead, cmdline)
    end,
  })
end

-- Complete the subcommand word only; the cmdline anchor skips any range
-- prefix (:'<,'>, :5,10) and stops after a full subcommand.
function M.complete(arg_lead, cmdline)
  local _, after = cmdline:find("Rex%s+", 1)
  if not after then
    return {}
  end
  local lead = cmdline:sub(after + 1)
  local dlead = lead:match("^debug%s+(%w*)$")
  if dlead then
    return vim.iter(debug_actions)
      :filter(function(s) return vim.startswith(s, dlead) end)
      :totable()
  end
  if not lead:match("^%w*$") then
    return {}
  end
  return vim.iter(subcommands)
    :filter(function(s) return vim.startswith(s, lead) end)
    :totable()
end

-- Dispatch a subcommand; `comment` and `ref` honor the command range (cursor
-- line by default, or :'<,'>/:5,10 when given).
function M.run(opts)
  local hn = require("rex-nvim")
  local sub = opts.fargs[1]
  if sub == "comment" then
    hn.comment_range(opts.line1, opts.line2)
  elseif sub == "ref" then
    hn.ref_range(opts.line1, opts.line2)
  elseif sub == "list" then
    hn.list_comments()
  elseif sub == "send" then
    hn.send_all({ submit = false })
  elseif sub == "submit" then
    hn.send_all({ submit = true })
  elseif sub == "debug" then
    local dbg = require("rex-nvim.debug")
    local action = opts.fargs[2] or (dbg.enabled and "log" or "on")
    if action == "on" or action == "off" then
      dbg.set(action == "on")
      vim.notify("rex-nvim: debug " .. action, vim.log.levels.INFO)
    elseif action == "log" then
      dbg.show()
    elseif action == "clear" then
      dbg.clear()
    else
      vim.notify("Rex debug: expected on|off|log|clear", vim.log.levels.ERROR, { title = "rex-nvim" })
    end
  else
    vim.notify(
      string.format("Rex: unknown subcommand %q (expected: %s)", sub or "", table.concat(subcommands, ", ")),
      vim.log.levels.ERROR,
      { title = "rex-nvim" }
    )
  end
end

return M
