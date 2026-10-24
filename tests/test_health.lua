local health = require("blit.health")
local terminal = require("blit.terminal")

local T = MiniTest.new_set()

---Run :checkhealth blit's check() against `caps` and return its warnings.
---@param caps blit.terminal.Capabilities
---@return string[]
local function warnings_for(caps)
  local saved_detect, saved_health = terminal.detect, vim.health
  local warnings = {}
  terminal.detect = function()
    return caps
  end
  vim.health = {
    start = function() end,
    ok = function() end,
    info = function() end,
    error = function() end,
    warn = function(msg)
      warnings[#warnings + 1] = msg
    end,
  }
  local ok, err = pcall(health.check)
  terminal.detect, vim.health = saved_detect, saved_health
  assert(ok, err)
  return warnings
end

T["names the multiplexer blit found"] = function()
  local warnings = warnings_for({
    terminal = "ghostty",
    multiplexer = "Zellij",
    gui_embed = false,
    supported = false,
    reason = "multiplexer",
  })
  MiniTest.expect.equality(warnings, { "blit is unsupported inside Zellij (silent no-op)." })
end

return T
