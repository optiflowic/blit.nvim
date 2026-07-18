# Manual Testing Checklist

Automated tests cover pure logic (escape sequence construction, chunking,
geometry, config validation, terminal detection). Actual pixel output is
terminal-dependent and not testable in CI — run this checklist on kitty and
WezTerm (and Ghostty when available) before tagging a release.

## Setup

- [ ] Have a small PNG file on disk and a scratch buffer open.
- [ ] `require("blit").show(path, { width = 20, height = 15 })` places the
      image below the cursor line; the returned handle is a table.
- [ ] `require("blit").clear(handle)` removes it.
- [ ] `require("blit").clear_all()` removes every currently shown image.

## Per-terminal checks (repeat for kitty, WezTerm, Ghostty)

- [ ] Image appears at the correct buffer line, sized to the requested
      cell columns/rows.
- [ ] Scrolling the image fully out of view then back in re-displays it
      without a visible retransmission delay (cache hit).
- [ ] Scrolling so the image is cut off at the top or bottom of the window
      hides it entirely (no partial image bleeding past the window edge) —
      this is the deliberate v0.x "fully visible or not shown" policy. A
      brief **blank gap** (reserved space, no image and no garbled pixels)
      during the scroll transition itself is expected — see
      `docs/spec/renderer-placement.md`'s "Known limitation" note. Fail
      this check only if the gap persists after scrolling settles, or if
      any actual image pixels appear outside the fully-visible case.
- [ ] Resizing the window (`WinResized`) repositions/hides the image
      correctly, with a single redraw per resize (not one per intermediate
      frame).
- [ ] Closing the window, wiping the buffer, or switching buffers in the
      anchor window removes the image (no leftover placement).
- [ ] Opening `:checkhealth` (or any command that opens a new tab) while an
      image is shown hides it in the new tab, and switching back to the
      original tab restores it (issue #16).
- [ ] Quitting Neovim (`:qa`) leaves no stray image on screen after exit.
- [ ] `:checkhealth blit` reports this terminal as supported.

## Ghostty

- [ ] Weight the checks above heavily for this terminal; it is the least
      battle-tested of the three supported terminals, per
      `docs/spec/kitty-graphics.md`.
