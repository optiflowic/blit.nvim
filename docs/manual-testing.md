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
- [ ] The very first `show()` call in a fresh session renders fully and
      correctly positioned immediately — no ghost/duplicate pixels one row
      below overlapping real buffer text, and no need for a scroll event
      to "self-correct" the position (issue #19).
- [ ] Showing a second image on a buffer line *above* an already-shown
      image repositions the first image to follow its shifted `virt_lines`
      block within about one debounce interval, instead of leaving it
      stuck at its old position overlapping buffer text (issue #18).
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

## WezTerm

- [ ] Anchor an image whose `virt_lines` block fits entirely within the
      window, then scroll so the window's *bottom* edge lands partway
      through the reserved rows (not far enough to scroll the image fully
      out of view) and let scrolling settle for a few seconds. No clipped
      image pixels should remain visible past the window's bottom edge —
      distinct from the expected transient blank-gap flash noted above,
      this is a persistent bleed of actual pixel data (issue #23). If
      pixels do stay stuck, scroll by one more line in either direction
      and confirm they clear within one more debounce interval — blit
      resends the hide command on every redraw pass a placement is
      invisible specifically so a later scroll gets another chance to
      clear a stuck placement (`docs/spec/renderer-placement.md`'s
      Lifecycle section); pixels stuck past that point are a regression.

## Ghostty

- [ ] Weight the checks above heavily for this terminal; it is the least
      battle-tested of the three supported terminals, per
      `docs/spec/kitty-graphics.md`.
- [ ] `show()` an image, then `clear()` (or `clear_all()`) it, then resize
      the Ghostty *terminal window itself* by dragging the OS window edge
      (not `:resize`/`vim.o.lines` from within Neovim), then `show()` the
      same path again. It must render via a fresh transmission — not
      silently render nothing (issue #24). If you can watch the escape
      sequences (or check `:messages`/a wrapper log), confirm the second
      `show()` after the resize includes a transmit (`a=T`), not just a
      bare placement (`a=p`) reusing the pre-resize id.
- [ ] Repeat the same steps *without* resizing in between: the second
      `show()` should reuse the cached id with a placement-only `a=p`, no
      retransmission — confirms the resize check isn't discarding the
      cache unconditionally.
