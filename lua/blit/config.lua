local M = {}

---@class blit.Config
---@field max_file_bytes integer
---@field debounce_ms integer
---@field redraw_throttle_ms integer

---@type blit.Config
M.defaults = {
  max_file_bytes = 5 * 1024 * 1024,
  debounce_ms = 16,
  redraw_throttle_ms = 100,
}

---@param user? table
---@return blit.Config
function M.merge(user)
  vim.validate({ user = { user, "table", true } })
  return vim.tbl_extend("force", {}, M.defaults, user or {})
end

return M
