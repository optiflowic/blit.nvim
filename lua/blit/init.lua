local config = require("blit.config")
local renderer = require("blit.renderer")

local M = {}

---@param opts? table
function M.setup(opts)
  M._config = config.merge(opts)
end

---@param path string
---@param opts? blit.ShowOpts
---@return blit.Handle? handle
---@return string? err
function M.show(path, opts)
  local cfg = M._config or config.merge(nil)
  local merged = vim.tbl_extend("force", {
    max_file_bytes = cfg.max_file_bytes,
    debounce_ms = cfg.debounce_ms,
    cell_aspect_ratio = cfg.cell_aspect_ratio,
  }, opts or {})
  return renderer.show(path, merged)
end

---@param handle blit.Handle
function M.clear(handle)
  renderer.clear(handle)
end

function M.clear_all()
  renderer.clear_all()
end

return M
