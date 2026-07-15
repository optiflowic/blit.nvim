# Terminal Detection — blit.nvim

This memo documents how `lua/blit/terminal.lua` decides whether it is safe
to emit kitty graphics protocol escape sequences, and how it writes them.
Per `AGENTS.md`'s Spec Memo Workflow, implementation code cites this memo
rather than re-deriving detection logic ad hoc.

## Purpose

blit must never emit escape sequences to a terminal that won't understand
them (garbage on screen, or worse, sequences interpreted as something
else). Detection is env-var based — no runtime protocol query (`a=q`) is
used, since that would require asynchronously reading stdin for the
terminal's response, which blit does not do in v0.x (see the "Response
handling" section of `docs/spec/kitty-graphics.md`).

## Detection matrix

Checked in this order; first match wins:

| Signal | Terminal |
|---|---|
| `$KITTY_WINDOW_ID` is set | `kitty` |
| `$TERM_PROGRAM == "WezTerm"` | `wezterm` |
| `$TERM_PROGRAM == "ghostty"` | `ghostty` |
| none of the above | unsupported → silent no-op |

`$WEZTERM_EXECUTABLE`/`$WEZTERM_PANE` and `$GHOSTTY_RESOURCES_DIR` also
exist as secondary signals for WezTerm/Ghostty respectively, but
`$TERM_PROGRAM` alone is sufficient and is what blit checks — it's the
single standard signal both terminals already set, so no extra env vars
are read.

## Exclusion checks

Applied regardless of which terminal (if any) matched above, in this fixed
precedence order:

1. **tmux**: `$TMUX` is set → excluded, `reason = "tmux"`. Per `AGENTS.md`,
   tmux is explicitly unsupported in v0.x even when the outer terminal is
   one of the three supported ones — tmux's own screen multiplexing breaks
   the graphics protocol's placement model.
2. **GUI / `--embed`**: `vim.fn.has("ttyout") == 0` → excluded,
   `reason = "gui_embed"`. This covers `nvim --embed` and GUI frontends
   (e.g. Neovide) that connect to Neovim over msgpack-RPC rather than a
   real pty — `has("ttyout")` is a Neovim built-in that reports whether
   stdout is connected to a real terminal, requiring no polyfill and no
   extra dependency, consistent with the Neovim ≥0.10 built-ins-only
   constraint.

Precedence is fixed (tmux checked before gui_embed) so that when both
conditions hold simultaneously, `detect()` always reports the same single
`reason` deterministically — this is asserted directly in
`tests/test_terminal_detect.lua` rather than left as an implementation
detail.

## tty write mechanism

blit never writes to `io.stdout` (via `print`/`io.write`): Neovim's own UI
protocol may be multiplexing that stream, and it may be redirected entirely
(e.g. `nvim --headless > file`), in which case bytes intended for the
terminal emulator would go nowhere the emulator can see them, or worse,
corrupt some other output.

Instead, `terminal.lua` opens `/dev/tty` directly — the controlling
terminal device, independent of stdout — via `vim.uv.fs_open`. This fd is
opened **lazily on the first `write()` call** and **cached for the
process's lifetime**; `reset_writer()` closes and drops the cached fd
(called by tests, and intended to be called by `renderer.lua`'s future
`VimLeavePre` cleanup). Opening once and reusing avoids a syscall per
redraw burst, which matters because the performance rules target
re-placing a scrolled image within one frame (~16ms) — reopening a fd on
every scroll-driven redraw would add avoidable latency for no benefit.
Measured via `vim.uv.hrtime()` (macOS, N=2000 `fs_open`+`fs_write`+`fs_close`
cycles vs. a cached fd): ~0.032ms/op open-per-call vs. ~0.0015ms/op cached,
about 21x slower per call — small in absolute terms per call, but avoidable
overhead on every redraw in a burst.
Automatic reopen-on-write-failure is deliberately not implemented
speculatively; if a real failure mode motivates it, that gets added with a
measurement, per `AGENTS.md`'s performance rules.

For testability (CI has no real controlling tty), `write(sequences, writer)`
accepts an injectable `writer` function; production code omits it and gets
the lazy-cached `/dev/tty` writer described above.

## Known false-negative / false-positive risks (accepted for v0.x)

- `$TERM_PROGRAM` can be spoofed or left stale by nested tools (e.g. a
  terminal launched from within another, or an SSH session into a host
  where the remote shell inherited the local `$TERM_PROGRAM`). blit trusts
  the env var as-is; there is no secondary verification query.
- `$KITTY_WINDOW_ID` can persist into subshells/nested sessions (e.g. after
  `ssh` into a machine where the variable was exported) even when the
  actual terminal on the other end is not kitty. This is an accepted,
  documented limitation, not solved in v0.x.

## Future considerations (not implemented)

DA1 (`\x1b[c`) or XTGETTCAP queries could provide a stronger capability
check than env vars alone, but require reading a terminal response
asynchronously — the same complexity blit avoids for protocol responses in
general (see `docs/spec/kitty-graphics.md`). Out of scope until a measured
need (real-world false detection reports) justifies the added complexity.
