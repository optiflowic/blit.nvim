local M = {}

---@class blit.Config
---@field max_file_bytes integer
---@field debounce_ms integer

---@type blit.Config
M.defaults = {
  max_file_bytes = 5 * 1024 * 1024,
  debounce_ms = 16,
}

---@param user? table
---@return blit.Config
function M.merge(user)
  return vim.tbl_extend("force", {}, M.defaults, user or {})
end

return M
