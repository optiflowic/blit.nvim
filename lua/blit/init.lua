local config = require("blit.config")

local M = {}

---@param opts? table
function M.setup(opts)
  M._config = config.merge(opts)
end

---@param _path string
---@param _opts? table
function M.show(_path, _opts) end

---@param _handle table
function M.clear(_handle) end

function M.clear_all() end

return M
