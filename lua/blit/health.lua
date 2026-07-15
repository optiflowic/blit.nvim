-- :checkhealth blit. Reports Neovim version, terminal capability detection
-- results, and the reason blit would no-op in this environment, if any. See
-- docs/spec/terminal-detection.md for the detection matrix this reflects.

local terminal = require("blit.terminal")

local M = {}

local REASON_MESSAGES = {
  tmux = "blit is explicitly unsupported under tmux in v0.x (silent no-op).",
  gui_embed = "GUI frontends and `--embed` are unsupported (silent no-op).",
  unsupported_terminal = "no supported terminal detected (kitty, WezTerm, Ghostty); silent no-op.",
}

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

  if caps.supported then
    vim.health.ok("blit is supported in this environment")
  else
    vim.health.warn(
      REASON_MESSAGES[caps.reason] or ("blit is unsupported: " .. tostring(caps.reason))
    )
  end
end

return M
