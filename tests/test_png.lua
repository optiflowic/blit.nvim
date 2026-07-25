local png = require("blit.png")

local SIGNATURE = string.char(137, 80, 78, 71, 13, 10, 26, 10)

---@param n integer
---@return string
local function u32be(n)
  return string.char(
    math.floor(n / 0x1000000) % 0x100,
    math.floor(n / 0x10000) % 0x100,
    math.floor(n / 0x100) % 0x100,
    n % 0x100
  )
end

---@param width integer
---@param height integer
---@param opts? { chunk_length?: integer, chunk_type?: string, crc?: string }
---@return string
local function png_bytes(width, height, opts)
  opts = opts or {}
  local ihdr_data = u32be(width) .. u32be(height) .. string.char(8, 6, 0, 0, 0)
  return SIGNATURE
    .. u32be(opts.chunk_length or 13)
    .. (opts.chunk_type or "IHDR")
    .. ihdr_data
    .. (opts.crc or string.char(0xDE, 0xAD, 0xBE, 0xEF))
end

local T = MiniTest.new_set()

T["read_ihdr"] = MiniTest.new_set()

T["read_ihdr"]["valid minimal PNG returns native dimensions"] = function()
  local dims, err = png.read_ihdr(png_bytes(100, 50))
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(dims, { width = 100, height = 50 })
end

T["read_ihdr"]["garbage CRC bytes do not affect the result (deliberately unchecked)"] = function()
  local dims, err = png.read_ihdr(png_bytes(10, 10, { crc = string.char(1, 2, 3, 4) }))
  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(dims, { width = 10, height = 10 })
end

T["read_ihdr"]["empty string is rejected"] = function()
  local dims, err = png.read_ihdr("")
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

T["read_ihdr"]["too-short buffer is rejected"] = function()
  local dims, err = png.read_ihdr(png_bytes(10, 10):sub(1, 20))
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

T["read_ihdr"]["bad signature is rejected"] = function()
  local bytes = "X" .. png_bytes(10, 10):sub(2)
  local dims, err = png.read_ihdr(bytes)
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

T["read_ihdr"]["chunk length other than 13 is rejected"] = function()
  local dims, err = png.read_ihdr(png_bytes(10, 10, { chunk_length = 12 }))
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

T["read_ihdr"]["first chunk not IHDR is rejected"] = function()
  local dims, err = png.read_ihdr(png_bytes(10, 10, { chunk_type = "IDAT" }))
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

T["read_ihdr"]["zero width is rejected"] = function()
  local dims, err = png.read_ihdr(png_bytes(0, 10))
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

T["read_ihdr"]["zero height is rejected"] = function()
  local dims, err = png.read_ihdr(png_bytes(10, 0))
  MiniTest.expect.equality(dims, nil)
  MiniTest.expect.equality(type(err), "string")
end

return T
