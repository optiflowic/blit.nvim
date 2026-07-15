# blit.nvim

[![CI](https://github.com/optiflowic/blit.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/optiflowic/blit.nvim/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](./LICENSE)

Zero-dependency image rendering for Neovim via the kitty graphics protocol.
No ImageMagick. No luarocks. No external binaries. Pure Lua on Neovim >= 0.10.

> **Status**: early v0.x. This release ships the protocol plumbing layer
> (terminal detection + kitty escape-sequence construction, unit-tested)
> but does not yet render images end-to-end — `show()`/`clear()`/`clear_all()`
> are reserved no-ops until the renderer layer lands.

## Requirements

- Neovim >= 0.10
- Terminal: kitty, WezTerm, or Ghostty
- tmux is explicitly unsupported in v0.x (blit no-ops under tmux)
- GUI frontends / `--embed` (e.g. Neovide) are unsupported (blit no-ops)

Run `:checkhealth blit` to see detection results for your environment.

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

### v0.x (unreleased)

- Protocol plumbing: kitty graphics escape-sequence construction, terminal
  capability detection, and tty transport (`lua/blit/terminal.lua`).
  No user-visible behavior yet — `setup()` only merges config.
