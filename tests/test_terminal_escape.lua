local terminal = require("blit.terminal")

local ESC = string.char(27)
local ID = terminal.ID_RANGE_START

local T = MiniTest.new_set()

T["chunk_base64"] = MiniTest.new_set()

T["chunk_base64"]["single chunk when under chunk_size"] = function()
  local chunks = terminal.chunk_base64(string.rep("a", 100), 4096)
  MiniTest.expect.equality(chunks, { string.rep("a", 100) })
end

T["chunk_base64"]["exact multiple of chunk_size"] = function()
  local payload = string.rep("a", 8192)
  local chunks = terminal.chunk_base64(payload, 4096)
  MiniTest.expect.equality(#chunks, 2)
  MiniTest.expect.equality(#chunks[1], 4096)
  MiniTest.expect.equality(#chunks[2], 4096)
  MiniTest.expect.equality(chunks[1] .. chunks[2], payload)
end

T["chunk_base64"]["off-boundary length"] = function()
  local payload = string.rep("a", 4097)
  local chunks = terminal.chunk_base64(payload, 4096)
  MiniTest.expect.equality(#chunks, 2)
  MiniTest.expect.equality(#chunks[1], 4096)
  MiniTest.expect.equality(#chunks[2], 1)
  MiniTest.expect.equality(chunks[1] .. chunks[2], payload)
end

T["chunk_base64"]["empty string"] = function()
  local chunks = terminal.chunk_base64("", 4096)
  MiniTest.expect.equality(chunks, { "" })
end

T["build_transmit"] = MiniTest.new_set()

T["build_transmit"]["single chunk transmit+display"] = function()
  local png_bytes = "hi"
  local sequences = terminal.build_transmit(png_bytes, { id = ID })
  local payload = vim.base64.encode(png_bytes)
  local expected = ESC .. "_Ga=T,f=100,t=d,i=" .. ID .. ",q=2,m=0;" .. payload .. ESC .. "\\"
  MiniTest.expect.equality(sequences, { expected })
end

T["build_transmit"]["multi-chunk exact boundary"] = function()
  -- 6144 raw bytes -> 8192 base64 chars (multiple of 3 -> no padding) -> 2 chunks of 4096
  local png_bytes = string.rep("A", 6144)
  local sequences = terminal.build_transmit(png_bytes, { id = ID })
  local payload = vim.base64.encode(png_bytes)
  MiniTest.expect.equality(#payload, 8192)
  MiniTest.expect.equality(#sequences, 2)

  local expected_first = ESC
    .. "_Ga=T,f=100,t=d,i="
    .. ID
    .. ",q=2,m=1;"
    .. payload:sub(1, 4096)
    .. ESC
    .. "\\"
  local expected_second = ESC .. "_Gm=0;" .. payload:sub(4097, 8192) .. ESC .. "\\"

  MiniTest.expect.equality(sequences[1], expected_first)
  MiniTest.expect.equality(sequences[2], expected_second)
end

T["build_transmit"]["continuation chunks carry only m="] = function()
  -- 9216 raw bytes -> 12288 base64 chars -> exactly 3 chunks of 4096
  local png_bytes = string.rep("A", 9216)
  local sequences = terminal.build_transmit(png_bytes, { id = ID })
  MiniTest.expect.equality(#sequences, 3)

  local function control_data(sequence)
    local start_idx = #(ESC .. "_G") + 1
    local sep_idx = sequence:find(";", 1, true)
    return sequence:sub(start_idx, sep_idx - 1)
  end

  MiniTest.expect.equality(control_data(sequences[2]), "m=1")
  MiniTest.expect.equality(control_data(sequences[3]), "m=0")
end

T["build_transmit"]["action t (transmit-only) differs only in a="] = function()
  local png_bytes = "hi"
  local display_seq = terminal.build_transmit(png_bytes, { id = ID, action = "T" })[1]
  local transmit_seq = terminal.build_transmit(png_bytes, { id = ID, action = "t" })[1]
  MiniTest.expect.equality(display_seq:gsub("a=T", "a=t"), transmit_seq)
end

T["build_transmit"]["deterministic across repeated calls"] = function()
  local png_bytes = "some bytes"
  local opts = { id = ID, placement = { columns = 10, rows = 5 } }
  local first = terminal.build_transmit(png_bytes, opts)
  local second = terminal.build_transmit(png_bytes, opts)
  MiniTest.expect.equality(first, second)
end

T["build_placement"] = MiniTest.new_set()

T["build_placement"]["minimal"] = function()
  local seq = terminal.build_placement(ID)
  MiniTest.expect.equality(seq, ESC .. "_Ga=p,i=" .. ID .. ESC .. "\\")
end

T["build_placement"]["with options in canonical order"] = function()
  local seq =
    terminal.build_placement(ID, { columns = 10, rows = 5, z_index = 3, no_move_cursor = true })
  MiniTest.expect.equality(seq, ESC .. "_Ga=p,i=" .. ID .. ",c=10,r=5,z=3,C=1" .. ESC .. "\\")
end

T["build_delete"] = MiniTest.new_set()

T["build_delete"]["default deletes placements only"] = function()
  local seq = terminal.build_delete(ID)
  MiniTest.expect.equality(seq, ESC .. "_Ga=d,d=i,i=" .. ID .. ESC .. "\\")
end

T["build_delete"]["free_data uses d=I"] = function()
  local seq = terminal.build_delete(ID, { free_data = true })
  MiniTest.expect.equality(seq, ESC .. "_Ga=d,d=I,i=" .. ID .. ESC .. "\\")
end

T["build_delete"]["never emits delete-all"] = function()
  for _, opts in ipairs({ nil, { free_data = true }, { free_data = false } }) do
    local seq = terminal.build_delete(ID, opts)
    MiniTest.expect.equality(seq:find("d=a", 1, true), nil)
  end
end

T["is_valid_id"] = MiniTest.new_set()

T["is_valid_id"]["range boundaries"] = function()
  MiniTest.expect.equality(terminal.is_valid_id(terminal.ID_RANGE_START), true)
  MiniTest.expect.equality(terminal.is_valid_id(terminal.ID_RANGE_END), true)
  MiniTest.expect.equality(terminal.is_valid_id(terminal.ID_RANGE_START - 1), false)
  MiniTest.expect.equality(terminal.is_valid_id(terminal.ID_RANGE_END + 1), false)
end

T["is_valid_id"]["rejects non-integer and non-number input"] = function()
  MiniTest.expect.equality(terminal.is_valid_id(0), false)
  MiniTest.expect.equality(terminal.is_valid_id(terminal.ID_RANGE_START + 0.5), false)
  MiniTest.expect.equality(terminal.is_valid_id("123"), false)
  MiniTest.expect.equality(terminal.is_valid_id(nil), false)
end

return T
