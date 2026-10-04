-- :checkhealth blit. Reports Neovim version, terminal capability detection
-- results, and the reason blit would no-op in this environment, if any. See
-- docs/spec/terminal-detection.md for the detection matrix this reflects.

local terminal = require("blit.terminal")
local renderer = require("blit.renderer")

local M = {}

local REASON_MESSAGES = {
  tmux = "blit is explicitly unsupported under tmux in v0.x (silent no-op).",
  gui_embed = "GUI frontends and `--embed` are unsupported (silent no-op).",
  unsupported_terminal = "no supported terminal detected (kitty, WezTerm, Ghostty); silent no-op.",
}

local WEZTERM_CRASH_WARNING = "known issue: sustained fast scrolling with an image anchored "
  .. "away from the top of the buffer can crash the WezTerm process (data loss risk). "
  .. "Root cause confirmed WezTerm-side, fix verified but not yet released upstream "
  .. "(https://github.com/wezterm/wezterm/issues/7953). See "
  .. "https://github.com/optiflowic/blit.nvim/issues/31 and README's Known Issues section."

function M.check()
  vim.health.start("blit")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 is required")
  end

  local caps = terminal.detect()

  if caps.terminal then
    vim.health.ok("Terminal detected: " .. caps.terminal)
  else
    vim.health.warn("No supported terminal detected (kitty, WezTerm, Ghostty)")
  end

  if caps.terminal == "wezterm" then
    vim.health.warn(WEZTERM_CRASH_WARNING)
  end

  if terminal.has_response_support() then
    vim.health.ok("Terminal error responses are reported here (Neovim >= 0.12)")
  else
    vim.health.info("Terminal error responses need Neovim >= 0.12; they stay suppressed")
  end

  for _, response_error in ipairs(renderer.response_errors()) do
    vim.health.error(
      ("terminal rejected image id %d (%s): %s"):format(
        response_error.id,
        response_error.path or "no longer displayed",
        response_error.message
      )
    )
  end

  if caps.supported then
    vim.health.ok("blit is supported in this environment")
  else
    vim.health.warn(
      REASON_MESSAGES[caps.reason] or ("blit is unsupported: " .. tostring(caps.reason))
    )
  end
end

return M
