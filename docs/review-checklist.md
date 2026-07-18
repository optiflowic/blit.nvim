# Review Checklist

Criteria for reviewing changes before merge, whether by a human or an AI agent.
`AGENTS.md` is the source of truth for constraints; this checklist operationalizes it.
Evaluate only the rules relevant to what actually changed in the diff.

Severity when reporting findings:

- `[must]` — blocks merge: constraint violation, protocol fidelity deviation, leak, security issue
- `[should]` — design/readability improvement; does not block
- `[nit]` — style/naming preference; does not block

## Constraints (category: constraint)
- [ ] No external binary invocation (`vim.system`, `io.popen`, `os.execute`) or luarocks/FFI requirement
- [ ] No API below Neovim 0.10; no polyfills
- [ ] Layer direction respected: `api → renderer → terminal`; no reverse requires
- [ ] Escape sequences constructed only in `terminal.lua`; autocmds/extmarks only in `renderer.lua`
- [ ] Unsupported environment (non-supported terminal, GUI, `--embed`, tmux) results in silent no-op, never emitted sequences

## Protocol Fidelity (category: fidelity)
- [ ] Behavior matches `docs/spec/kitty-graphics.md` (control keys, chunk size, base64 framing)
- [ ] Image IDs allocated within our reserved range; no `a=d,d=a` (delete-all)
- [ ] Re-placement uses `a=p` with existing ID; no pixel re-transmission

## Lifecycle & Leaks (category: leak)
- [ ] Every placement path has a deletion path (buffer wipe, window close, `VimLeavePre`)
- [ ] Autocmds/timers torn down when the last image is cleared (quiescent idle)
- [ ] Handle state lives in the single handle table; no state scattered across modules

## Performance (category: perf)
- [ ] No I/O, detection, or autocmd registration at `require`/`setup` time
- [ ] Scroll-driven redraws debounced; single redraw per isolated event, and
      sustained bursts capped to roughly one redraw per `redraw_throttle_ms`
      (not one per event) rather than only per-event debounce
- [ ] Base64 payload dropped after transmission; cache keyed by `(path, mtime)`
- [ ] Synchronous file reads guarded by `max_file_bytes`
- [ ] Perf-motivated complexity cites a `vim.uv.hrtime()` measurement

## API & Errors (category: api)
- [ ] Expected failures return `nil, err_msg`; `error()` only for programmer mistakes via `vim.validate`
- [ ] No `vim.notify` from library code
- [ ] Public functions have LuaLS annotations; breaking changes called out (v0.x policy)
- [ ] `setup()` remains idempotent

## Tests & Docs (category: test/docs)
- [ ] Pure logic (sequence construction, chunking, geometry, config validation) has unit tests
- [ ] Golden strings updated intentionally, not to make tests pass
- [ ] `:checkhealth` reflects new capabilities/exclusions
- [ ] Vimdoc and README updated for public API changes

## General Lua Quality (category: style)
- [ ] Guard clauses over nested ifs; small functions
- [ ] snake_case; predicate-style boolean names; conventional abbreviations only
- [ ] `stylua` / `selene` clean
