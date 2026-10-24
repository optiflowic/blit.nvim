local terminal = require("blit.terminal")

local function tty_ok()
  return 1
end

local function tty_embed()
  return 0
end

local T = MiniTest.new_set()

T["detect_terminal"] = MiniTest.new_set()

T["detect_terminal"]["kitty via KITTY_WINDOW_ID"] = function()
  MiniTest.expect.equality(terminal.detect_terminal({ KITTY_WINDOW_ID = "1" }), "kitty")
end

T["detect_terminal"]["wezterm via TERM_PROGRAM"] = function()
  MiniTest.expect.equality(terminal.detect_terminal({ TERM_PROGRAM = "WezTerm" }), "wezterm")
end

T["detect_terminal"]["ghostty via TERM_PROGRAM"] = function()
  MiniTest.expect.equality(terminal.detect_terminal({ TERM_PROGRAM = "ghostty" }), "ghostty")
end

T["detect_terminal"]["unrecognized TERM_PROGRAM is nil"] = function()
  MiniTest.expect.equality(terminal.detect_terminal({ TERM_PROGRAM = "iTerm.app" }), nil)
end

T["detect_terminal"]["no signals is nil"] = function()
  MiniTest.expect.equality(terminal.detect_terminal({}), nil)
end

T["detect_multiplexer"] = MiniTest.new_set()

T["detect_multiplexer"]["tmux from TMUX"] = function()
  local env = { TMUX = "/tmp/tmux-1000/default,123,0" }
  MiniTest.expect.equality(terminal.detect_multiplexer(env), "tmux")
end

T["detect_multiplexer"]["Zellij from ZELLIJ"] = function()
  MiniTest.expect.equality(terminal.detect_multiplexer({ ZELLIJ = "0" }), "Zellij")
end

T["detect_multiplexer"]["herdr from HERDR_ENV"] = function()
  MiniTest.expect.equality(terminal.detect_multiplexer({ HERDR_ENV = "1" }), "herdr")
end

T["detect_multiplexer"]["GNU screen from STY"] = function()
  local env = { STY = "12345.pts-0.host" }
  MiniTest.expect.equality(terminal.detect_multiplexer(env), "GNU screen")
end

T["detect_multiplexer"]["herdr wins over the TMUX it inherits"] = function()
  local env = { TMUX = "/tmp/tmux-1000/default,123,0", HERDR_ENV = "1" }
  MiniTest.expect.equality(terminal.detect_multiplexer(env), "herdr")
end

T["detect_multiplexer"]["nil when none set"] = function()
  MiniTest.expect.equality(terminal.detect_multiplexer({}), nil)
end

T["is_gui_embed"] = MiniTest.new_set()

T["is_gui_embed"]["true when ttyout is 0"] = function()
  MiniTest.expect.equality(terminal.is_gui_embed(tty_embed), true)
end

T["is_gui_embed"]["false when ttyout is 1"] = function()
  MiniTest.expect.equality(terminal.is_gui_embed(tty_ok), false)
end

T["detect"] = MiniTest.new_set()

T["detect"]["fully supported"] = function()
  local caps = terminal.detect({ KITTY_WINDOW_ID = "1" }, tty_ok)
  MiniTest.expect.equality(caps.terminal, "kitty")
  MiniTest.expect.equality(caps.multiplexer, nil)
  MiniTest.expect.equality(caps.gui_embed, false)
  MiniTest.expect.equality(caps.supported, true)
  MiniTest.expect.equality(caps.reason, nil)
end

T["detect"]["each multiplexer excludes even inside a supported terminal"] = function()
  for var, name in pairs({
    TMUX = "tmux",
    ZELLIJ = "Zellij",
    HERDR_ENV = "herdr",
    STY = "GNU screen",
  }) do
    local caps = terminal.detect({ TERM_PROGRAM = "ghostty", [var] = "x" }, tty_ok)
    MiniTest.expect.equality(caps.supported, false)
    MiniTest.expect.equality(caps.reason, "multiplexer")
    MiniTest.expect.equality(caps.multiplexer, name)
  end
end

T["detect"]["herdr with an inherited TMUX reports herdr"] = function()
  local caps = terminal.detect({ TERM_PROGRAM = "ghostty", TMUX = "x", HERDR_ENV = "1" }, tty_ok)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "multiplexer")
  MiniTest.expect.equality(caps.multiplexer, "herdr")
end

T["detect"]["gui_embed excludes"] = function()
  local caps = terminal.detect({ KITTY_WINDOW_ID = "1" }, tty_embed)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "gui_embed")
end

T["detect"]["multiplexer takes precedence over gui_embed"] = function()
  local caps = terminal.detect({ KITTY_WINDOW_ID = "1", ZELLIJ = "0" }, tty_embed)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "multiplexer")
end

T["detect"]["unsupported terminal with no other exclusion"] = function()
  local caps = terminal.detect({}, tty_ok)
  MiniTest.expect.equality(caps.terminal, nil)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "unsupported_terminal")
end

T["detect"]["smoke test against live env/vim.fn.has"] = function()
  local ok = pcall(terminal.detect)
  MiniTest.expect.equality(ok, true)
end

return T
