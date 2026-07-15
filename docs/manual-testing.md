# Manual Testing Checklist

Automated tests cover pure logic (escape sequence construction, chunking,
geometry, config validation, terminal detection). Actual pixel output is
terminal-dependent and not testable in CI — run this checklist on kitty and
WezTerm (and Ghostty when available) before tagging a release.

**Current status: not applicable yet.** This release has no renderer —
`show()` does not place any image on screen. This checklist is scaffolded
now so it's ready to fill in once the renderer layer lands.

## Setup

- [ ] (placeholder — fill in once `show()` renders images)

## kitty

- [ ] (placeholder)

## WezTerm

- [ ] (placeholder)

## Ghostty

- [ ] (placeholder — weight this terminal's checks heavily; it is the
      least battle-tested of the three supported terminals, per
      `docs/spec/kitty-graphics.md`)
