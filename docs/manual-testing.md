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
- [ ] `show(path, { width = 10, height = 5, col = 8 })` renders the image
      8 cells to the right of the window's text-area left edge (i.e. past
      any number/sign column, aligned with the 9th text cell), inside its
      reserved blank rows (issue #9). Scroll it partway off the top of the
      window and confirm the cropped tail keeps the same horizontal
      offset. Repeat with a `col` large enough that the image overhangs
      the window's right edge: the visible part must be a clean
      column-cropped slice, not stretched or wrapped onto the next row.
- [ ] Scrolling the image fully out of view then back in re-displays it
      without a visible retransmission delay (cache hit).
- [ ] `show()` a PNG, `clear()` it, overwrite the file at the same path
      with a visibly different PNG, then `show()` that path again (issue
      #11, superseded-mtime eviction). The new image must render, with no
      leftover copy of the old one anywhere on screen.
- [ ] `show()` the same PNG path twice at two different buffer lines
      without `clear()`-ing the first in between (issue #10, multi-location
      fan-out). Both copies must render correctly and simultaneously — not
      just the second one, and not the first one moved/disappeared. Then
      `clear()` only the first handle: the second must remain visible,
      unaffected. Finally `clear()` the second handle too and confirm no
      stray pixels remain from either.
- [ ] Scrolling so the image is cut off at the top or bottom of the window
      shows a **cropped** slice of the image (the still-visible portion,
      correctly sized to the remaining cell span) instead of a blank gap or
      the image disappearing entirely — see `docs/spec/renderer-placement.md`'s
      "Visibility policy" section. Only scrolling it fully out of view (no
      overlap with the window at all) should hide it. Fail this check if a
      blank gap or garbled/stretched pixels appear instead of a clean crop —
      on WezTerm specifically, apply the scroll-once-more recovery pattern
      from the WezTerm section below before failing this check.
- [ ] While cropped at only the top or bottom edge (rows clipped, columns
      not), confirm the full width of the image still renders — no sliver
      or blank space on the left/right side. This verifies the assumption
      noted in `docs/spec/kitty-graphics.md`'s "Source-rectangle cropping"
      section that the terminal defaults an omitted axis's `x=`/`w=` (or
      `y=`/`h=`) to the full image span rather than a stale/zero size. If
      the un-clipped axis renders wrong, see that section's fallback.
- [ ] After the image has been shown cropped (per the check above), scroll
      it back to fully within the window. Confirm it renders as the
      complete, uncropped image, not stuck showing the previous crop
      rectangle — this verifies the assumption noted in
      `docs/spec/kitty-graphics.md`'s "Source-rectangle cropping" section
      that re-placing with no crop keys resets to the full image. If it
      stays stuck cropped, see that section's fallback.
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
- [ ] (Neovim >= 0.12) After normal use — show, scroll, resize, clear —
      typing still works normally (no stray characters inserted) and
      `:checkhealth blit` lists no "terminal rejected image" error.
- [ ] (Neovim >= 0.12) `show()` a file with a valid PNG signature and IHDR
      but corrupt image data: no image appears, and on kitty and Ghostty
      `:checkhealth blit` lists a timestamped "terminal rejected image"
      error naming that file. WezTerm sends no error response for this
      case, so nothing is listed there (see
      `docs/spec/kitty-graphics.md`'s "Per-terminal quirks").

## WezTerm

- [ ] Anchor an image whose `virt_lines` block fits entirely within the
      window, then scroll so the window's *bottom* edge lands partway
      through the reserved rows (not far enough to scroll the image fully
      out of view) and let scrolling settle for a few seconds. The image
      should show a clean crop up to the window's bottom edge — no pixels
      bleeding past the edge, and no stale/incorrect crop amount lingering
      once scrolling settles (WezTerm's scroll-driven repaint lag, issue
      #23, previously showed this as stuck pixels past a hide command; with
      cropping there is no hide at this edge, so watch specifically for a
      crop boundary that doesn't track the window edge). If it looks wrong
      immediately after scrolling, scroll by one more line in either
      direction and confirm it corrects within one more debounce interval —
      blit resends the placement on every redraw pass a handle is visible
      specifically so a later scroll gets another chance to fix a stuck
      frame (`docs/spec/renderer-placement.md`'s Lifecycle section); still
      wrong past that point is a regression.
- [ ] Repeat the same check at the window's *top* edge: anchor an image
      near the top of the buffer, scroll down (gradually, e.g. holding
      `<C-e>`) so its `virt_lines` block straddles the window's top edge
      (not far enough to scroll it fully out of view), and let scrolling
      settle for a few seconds. This is the same WezTerm scroll-driven
      repaint lag as the bottom-edge case above, just at the opposite edge
      (issue #28) — again, a clean crop tracking the window's top edge is
      expected (this is the exact scenario Issue #6 fixed: previously a
      blank gap, now a cropped image), not a blank gap or stuck stale crop.
      Same recovery pattern applies if it looks wrong immediately after
      scrolling.
- [ ] `show()` an image, then `clear()` (or `clear_all()`) it, *without*
      scrolling or otherwise triggering a redraw afterward. No stuck image
      pixels should remain visible at that location, even immediately after
      the call returns — `destroy_handle` self-schedules a bounded resend of
      its own `a=d` for exactly this case (issue #27), so waiting up to a
      few debounce intervals with zero further input should still be enough
      to clear it. Pixels stuck past that point (or a second `clear_all()`
      call needed to clear them) are a regression.
- [ ] **Known limitation, not a release blocker** (issue #31): anchor an
      image ~50 lines down in a long buffer, then scroll continuously (e.g.
      hold `<C-e>` or `j`) so its screen row sweeps through many distinct
      rows. Confirm the WezTerm process crash still reproduces about the
      same way (rendering gets sluggish within ~10 lines of scroll, then the
      WezTerm process itself dies within a few seconds). Root cause is
      confirmed WezTerm-side (wezterm/wezterm#7953), with a fix verified but
      not yet released upstream — this item is *expected* to still fail and
      must not block tagging the release. Only stop and escalate if:
      (a) it no longer reproduces at all — check whether the WezTerm version
      under test already includes wezterm/wezterm#7953's fix, and if so
      re-verify and close #31 instead of just checking this box; or (b) the
      same crash now reproduces on kitty or Ghostty too — that would mean
      the trigger isn't WezTerm-specific after all, a new and more serious
      bug.

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
- [ ] `show()` an image and leave it visible (do not `clear()` it), then
      resize the Ghostty *terminal window itself* by dragging the OS window
      edge, even by a small amount. The image must reappear within roughly a
      few hundred milliseconds of the drag stopping, not disappear
      permanently (issue #34). Try both a single quick drag and a slower,
      continuous one that crosses several cell sizes along the way — both
      must recover, and the image should not flicker/fail intermittently
      partway through a single continuous drag. Repeat the resize a second
      and third time in a row without any other input in between — it must
      keep recovering every time, not just the first.
