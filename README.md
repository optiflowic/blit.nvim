# blit.nvim

[![CI](https://github.com/optiflowic/blit.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/optiflowic/blit.nvim/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)

Zero-dependency image rendering for Neovim via the kitty graphics protocol.
No ImageMagick. No luarocks. No external binaries. Pure Lua on Neovim >= 0.10.

> **Status**: v0.2.0 released. `show()`/`clear()`/`clear_all()` render and remove
> PNG placements via the kitty graphics protocol. A placement scrolled
> partway past a window edge shows a cropped slice of the image rather than
> disappearing; it's hidden only once it has no overlap with the window at
> all. `width`/`height` in `show()` are optional — an omitted dimension is
> derived from the PNG's native aspect ratio. See
> `docs/spec/renderer-placement.md` for the design.

## Requirements

- Neovim >= 0.10
- Terminal: kitty, WezTerm, or Ghostty
- tmux is explicitly unsupported in v0.x (blit no-ops under tmux)
- GUI frontends / `--embed` (e.g. Neovide) are unsupported (blit no-ops)

Run `:checkhealth blit` to see detection results for your environment. On
Neovim >= 0.12 it also lists any error the terminal sent back for an image
(e.g. a PNG it rejected); on 0.10 / 0.11 those errors are not available.
WezTerm sends no such error for a rejected PNG, so none is listed there.

## Install

```lua
-- lazy.nvim
{ "optiflowic/blit.nvim", opts = {} }
```

## Constraints

- Zero external dependencies — never requires ImageMagick, luarocks, Python,
  Node, or any external binary.
- PNG only (v0.x). Other formats are out of scope until v2.
- Only kitty, WezTerm, and Ghostty are supported; every other terminal
  (or an unsupported environment such as tmux or a GUI frontend) is a
  silent no-op, reported via `:checkhealth`.

See `AGENTS.md` for the full set of project constraints and architecture.

## Known Issues

- **A buffer split into a second window shows blank space, not the image.**
  `show()` binds a placement to one specific window; if the same buffer is
  also open in another window (`:split`/`:vsplit`), that window renders the
  reserved blank `virt_lines` rows with no image in them — `show()` doesn't
  auto-detect the split and place into it. Work around this today by calling
  `show()` again with `opts.win` set to the second window and the same
  `path`: blit reuses the already-transmitted image data instead of
  re-sending it, adding an independent placement for the new window at no
  extra transmission cost ([#10](https://github.com/optiflowic/blit.nvim/issues/10)).

- **WezTerm: process crash under sustained fast scrolling** ([#31](https://github.com/optiflowic/blit.nvim/issues/31)).
  Scrolling quickly and continuously with an image anchored away from the top
  of the buffer can crash the WezTerm process itself (not just the pane),
  taking the Neovim session down with it. Root cause is confirmed WezTerm-side
  (an unbounded render-quad count under placement reposition + scroll, filed
  upstream as [wezterm/wezterm#7953](https://github.com/wezterm/wezterm/issues/7953))
  with a verified fix, but that fix hasn't shipped in a WezTerm release yet.
  Nothing to change on blit's side — this will be re-verified and closed once
  the fix lands upstream. Until then, avoid sustained fast scrolling on WezTerm
  while an image is anchored far down a long buffer.

## Development

```sh
make                # format-check + lint + test (same as CI)
make test           # run unit tests (mini.test, headless nvim)
make format-check   # stylua --check .
make lint           # selene .
```

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md). Bug reports and feature
requests use the [issue templates](https://github.com/optiflowic/blit.nvim/issues/new/choose);
general questions go in [Discussions](https://github.com/optiflowic/blit.nvim/discussions).

## Changelog

### Unreleased

- **Breaking**: `show()`'s `opts.col` now positions the image horizontally,
  as a 0-indexed display-cell offset from the window's text-area left edge
  ([#9](https://github.com/optiflowic/blit.nvim/issues/9)). It was previously
  documented as an anchor byte column and silently ignored; it is now
  validated as a non-negative integer, so a negative or fractional `col`
  that used to be accepted raises an argument error.
- On Neovim >= 0.12, error responses from the terminal (e.g. a rejected
  PNG) are recorded and listed by `:checkhealth blit`
  ([#12](https://github.com/optiflowic/blit.nvim/issues/12)). Neovim 0.10 /
  0.11 behave as before.

### v0.2.0 (2026-08-08)

- Renderer: a placement scrolled partway past a window edge shows a cropped
  slice of the image instead of being hidden; it's hidden only once it has no
  overlap with the window at all (`lua/blit/renderer.lua`).
- `show()`: an omitted `width` or `height` is derived from the PNG's native
  aspect ratio instead of being required.
- Fixed a wrapped anchor-line row miscalculation in `virt_lines` placement,
  and a Ghostty resize-retransmit retry that could get stuck after a failed
  attempt.

### v0.1.0 (2026-07-25)

- Renderer: `show()`/`clear()`/`clear_all()` place and remove PNG images via
  extmark-reserved `virt_lines`, with scroll/resize redraw (debounced),
  transmission caching by `(path, mtime)`, and full lifecycle cleanup
  (`lua/blit/renderer.lua`). Images are shown only when fully visible; no
  partial/cropped placement in v0.x.
- Protocol plumbing: kitty graphics escape-sequence construction, terminal
  capability detection, and tty transport (`lua/blit/terminal.lua`).
