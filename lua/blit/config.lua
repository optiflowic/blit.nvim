local M = {}

---@class blit.Config
---@field max_file_bytes integer
---@field debounce_ms integer
---@field cell_aspect_ratio number assumed terminal cell width-px/height-px
---ratio, used only to fill in a `show()` `width`/`height` the caller omitted
---(see `docs/spec/renderer-placement.md`'s "Reserving space: virt_lines").
---blit never queries the terminal for its real cell-pixel size (out of
---scope, see `docs/spec/kitty-graphics.md`), so this is a fixed approximation.

---@type blit.Config
M.defaults = {
  max_file_bytes = 5 * 1024 * 1024,
  debounce_ms = 16,
  cell_aspect_ratio = 0.5,
}

---@param user? table
---@return blit.Config
function M.merge(user)
  vim.validate({ user = { user, "table", true } })
  return vim.tbl_extend("force", {}, M.defaults, user or {})
end

return M
