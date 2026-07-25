-- Minimal PNG IHDR metadata reader. This is not a PNG decoder: no pixel data
-- is ever read or produced, only the native width/height needed by
-- renderer.lua's source-rectangle crop math (docs/spec/renderer-placement.md's
-- "Visibility policy"). Pure function, no I/O — the caller (renderer.lua)
-- already reads the file bytes for transmission.

local M = {}

local SIGNATURE = string.char(137, 80, 78, 71, 13, 10, 26, 10)
local IHDR_DATA_LENGTH = 13
local MIN_BYTES = 8 + 4 + 4 + IHDR_DATA_LENGTH

---@param bytes string
---@param offset integer 1-indexed start of a 4-byte big-endian field
---@return integer
local function read_u32be(bytes, offset)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  return b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
end

---@class blit.png.Dimensions
---@field width integer native pixel width
---@field height integer native pixel height

---@param bytes string raw file bytes
---@return blit.png.Dimensions? dims
---@return string? err
function M.read_ihdr(bytes)
  if #bytes < MIN_BYTES then
    return nil, "blit.png: file too short to be a PNG"
  end
  if bytes:sub(1, 8) ~= SIGNATURE then
    return nil, "blit.png: not a PNG (bad signature)"
  end
  if read_u32be(bytes, 9) ~= IHDR_DATA_LENGTH then
    return nil, "blit.png: malformed IHDR chunk (unexpected length)"
  end
  if bytes:sub(13, 16) ~= "IHDR" then
    return nil, "blit.png: malformed PNG (first chunk is not IHDR)"
  end

  local width = read_u32be(bytes, 17)
  local height = read_u32be(bytes, 21)
  if width <= 0 or height <= 0 then
    return nil, "blit.png: malformed IHDR (non-positive dimensions)"
  end

  return { width = width, height = height }
end

return M
