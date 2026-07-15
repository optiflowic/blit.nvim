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

T["has_tmux"] = MiniTest.new_set()

T["has_tmux"]["true when TMUX set"] = function()
  MiniTest.expect.equality(terminal.has_tmux({ TMUX = "/tmp/tmux-1000/default,123,0" }), true)
end

T["has_tmux"]["false when unset"] = function()
  MiniTest.expect.equality(terminal.has_tmux({}), false)
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
  MiniTest.expect.equality(caps.tmux, false)
  MiniTest.expect.equality(caps.gui_embed, false)
  MiniTest.expect.equality(caps.supported, true)
  MiniTest.expect.equality(caps.reason, nil)
end

T["detect"]["tmux excludes even inside a supported terminal"] = function()
  local caps = terminal.detect({ KITTY_WINDOW_ID = "1", TMUX = "x" }, tty_ok)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "tmux")
end

T["detect"]["gui_embed excludes"] = function()
  local caps = terminal.detect({ KITTY_WINDOW_ID = "1" }, tty_embed)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "gui_embed")
end

T["detect"]["tmux takes precedence over gui_embed"] = function()
  local caps = terminal.detect({ KITTY_WINDOW_ID = "1", TMUX = "x" }, tty_embed)
  MiniTest.expect.equality(caps.supported, false)
  MiniTest.expect.equality(caps.reason, "tmux")
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
