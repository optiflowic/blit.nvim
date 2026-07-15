# blit.nvim

Zero-dependency image rendering for Neovim via the kitty graphics protocol.
No ImageMagick. No luarocks. No external binaries. Pure Lua on Neovim >= 0.10.

## Non-Negotiable Constraints

- **Zero external dependencies.** Never add a requirement on ImageMagick, luarocks,
  Python, Node, or any external binary. If a feature cannot be built without one,
  it is out of scope (or becomes an optional, auto-detected enhancement — ask first).
- **Neovim >= 0.10 only.** Use built-ins: `vim.base64`, `vim.system`, `vim.uv`,
  `vim.api.nvim_buf_set_extmark`. Never vendor polyfills for older versions.
- **PNG only (v0.x).** The kitty protocol accepts PNG natively (`f=100`). Other
  formats are out of scope until v2.
- **Supported terminals: kitty, WezTerm, Ghostty.** Detect via env vars. On any
  other terminal (or GUI/`--embed`), silently no-op and report via `:checkhealth`.
  Never emit escape sequences to an unsupported terminal.
- **tmux is explicitly unsupported in v0.x.** Detect (`$TMUX`) and no-op.

## Architecture

Dependency direction is strictly one-way: `api → renderer → terminal`.
Lower layers never require upper layers. `config` and `health` are leaf utilities.

```
lua/blit/
  init.lua        -- public API: setup(), show(), clear(), clear_all()
  config.lua      -- defaults + user config merge + validation
  terminal.lua    -- protocol layer: capability detection, escape sequence
                  -- construction (chunked base64, f=100), tty write. Knows
                  -- NOTHING about buffers, windows, or extmarks.
  renderer.lua    -- placement layer: buffer/window -> screen cell coordinate
                  -- conversion, extmark virtual lines, image id allocation,
                  -- redraw on WinScrolled/WinResized/BufWinLeave, lifecycle.
                  -- Knows NOTHING about escape sequence syntax.
  health.lua      -- :checkhealth blit — terminal detection result, protocol
                  -- support, Neovim version, tmux/GUI exclusion reasons.
```

Rules:
- `terminal.lua` separates sequence CONSTRUCTION (pure functions: given image data
  and geometry, return escape sequence strings — unit-testable byte-exact) from
  sequence TRANSPORT (a single `write()` that owns the tty channel).
- tty transport: never write to `io.stdout` directly (conflicts with Neovim's UI
  protocol and may be redirected). Open the controlling tty explicitly. The chosen
  mechanism and its rationale live in `docs/spec/terminal-detection.md`.
- Image IDs: the kitty protocol ID space is shared terminal-wide with other
  plugins (image.nvim, snacks.image). Allocate our IDs inside a fixed reserved
  range (documented in the spec memo) to avoid clobbering foreign images. Never
  use `a=d,d=a` (delete all); only delete IDs we own.
- `renderer.lua` owns ALL autocmds and extmarks. No other module creates autocmds.
  Autocmds live in a single `augroup("blit", ...)`; extmarks in one
  `nvim_create_namespace("blit")`. Register `VimLeavePre` cleanup that deletes
  every image we placed.
- `init.lua` is thin orchestration only. No business logic. `setup()` must be
  idempotent (safe to call twice; re-entrant config merge, no duplicate autocmds).
- One image = one handle table `{ id, buf, extmark_id, path, geometry }`. Never
  spread this state across modules.

## Coding Standards

- Format: `stylua` (config in repo). Lint: `selene`. Both must pass before commit.
- Every public function gets LuaLS annotations (`---@param`, `---@return`).
  `lua/blit/types.lua` may hold shared `---@class` defs if they grow.
- Errors: library code never calls `error()` for expected failures (missing file,
  unsupported terminal). Return `nil, err_msg`. Reserve `error()` for programmer
  mistakes (bad argument types) via `vim.validate`.
- No `vim.notify` spam. Failures surface through return values and `:checkhealth`.
- Naming: snake_case functions/locals, no abbreviations except conventional ones
  (buf, win, col, ns). Boolean names read as predicates (`is_supported`, `has_tmux`).
- Guard clauses over nested ifs. Small functions. If a function needs a comment
  explaining "sections", split it.

## Performance Rules

- Zero startup cost: `require("blit")` and `setup()` do no I/O, no terminal
  detection, no autocmd registration. Everything is deferred until the first
  `show()` call. Target: unmeasurable (<0.1ms) in lazy.nvim profile.
- Debounce scroll-driven redraws (`WinScrolled`): single deferred redraw per burst,
  never one redraw per event. Debounce interval is a config value with a sane default.
  Target: image re-placed within one frame (~16ms) after scroll settles.
- Re-placement of an already-transmitted image must reuse its ID (`a=p`) — never
  re-transmit pixel data on scroll/resize.
- Cache transmitted images by `(path, mtime)`: re-showing a cached image is a
  placement only. Drop base64 payloads after transmission; keep only IDs and
  geometry in Lua memory.
- Synchronous file reads are allowed only under a size guard (config `max_file_bytes`,
  default a few MB). Larger files: refuse with `nil, err`.
- No timers or autocmds active when zero images are displayed (fully quiescent idle).
- Measure before optimizing: use `vim.uv.hrtime()` around suspected hot paths.
  No speculative optimization; every perf-motivated complexity increase must cite
  a measurement.

## Spec Memo Workflow

Before implementing against an external spec, write/update a memo in `docs/spec/`:

- `docs/spec/kitty-graphics.md` — the subset of the kitty graphics protocol we use:
  transmission (`a=T`, `f=100`, chunked `m=0/1`, 4096-byte chunks), placement
  (`c=`, `r=`, `z=`), deletion (`a=d`), unicode placeholders (documented but unused
  in v0.x), quirks per terminal (WezTerm: no placeholder support, known scroll lag).
- `docs/spec/terminal-detection.md` — detection matrix: env vars, DA1 queries if
  used, GUI/embed exclusion logic.

Implementation must cite the memo, not raw upstream docs. If reality diverges from
the memo, fix the memo in the same PR.

## Testing

- Framework: `mini.test` (dev-time only dependency, never a runtime one).
- Unit test targets: escape sequence construction (byte-exact golden strings),
  chunking boundaries, geometry math (cell conversion, clipping), config validation,
  terminal detection (mock env vars).
- NOT tested automatically: actual pixel output (terminal-dependent). Manual test
  checklist lives in `docs/manual-testing.md` — run it on kitty + WezTerm before
  tagging a release.
- Bug fixes must include a regression test for the fixed behavior when the bug is in
  pure logic; if terminal-dependent, add a step to `docs/manual-testing.md` instead.
- No coverage metric. Quality gates are: unit tests for enumerated boundary conditions
  (see review checklist), lint/format clean, and the manual checklist before release.
- Run: `make test` (headless nvim). Tests must pass on Linux and macOS.

## Definition of Done (per feature)

1. Spec memo updated if protocol behavior involved
2. LuaLS annotations on all new public functions
3. Unit tests for pure logic; manual checklist updated if visual behavior changed
4. `stylua --check .` and `selene .` clean
5. `:checkhealth blit` reflects any new capability/exclusion
6. Vimdoc (`doc/blit.txt`) updated for any public API change
7. README updated if user-facing (API, constraints, supported terminals)

## Workflow

- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`).
  Small, single-purpose commits.
- CI (GitHub Actions): `stylua --check`, `selene`, `make test` on Linux + macOS.
  All green before merge.
- v0.x: breaking API changes are allowed but must be called out in the commit body
  and README changelog section.
- When a spec is ambiguous or two valid designs conflict with these rules:
  STOP and ask. Do not pick silently. Present options with trade-offs.

## Out of Scope (do not implement without explicit approval)

- tmux passthrough, sixel, ueberzugpp backends
- Non-PNG decoding, ImageMagick/ffmpeg integration
- Markdown/filetype integration (belongs to a separate plugin built on top)
- Async image downloads from URLs Async image downloads from URLs
