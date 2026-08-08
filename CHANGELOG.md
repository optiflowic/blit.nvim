# Changelog

## [0.2.0](https://github.com/optiflowic/blit.nvim/compare/blit.nvim-v0.1.0...blit.nvim-v0.2.0) (2026-07-25)


### Features

* crop partially-visible placements instead of hiding them ([#39](https://github.com/optiflowic/blit.nvim/issues/39)) ([44a9477](https://github.com/optiflowic/blit.nvim/commit/44a9477fe63e1485120427fd79df7037a34ed7e3))
* derive an omitted show() width/height from the PNG's native aspect ratio ([#45](https://github.com/optiflowic/blit.nvim/issues/45)) ([3273414](https://github.com/optiflowic/blit.nvim/commit/3273414a452c9dc05b60f4c312259e5791d0fe8e))


### Bug Fixes

* account for wrapped anchor line rows when placing virt_lines ([#41](https://github.com/optiflowic/blit.nvim/issues/41)) ([ae0fda8](https://github.com/optiflowic/blit.nvim/commit/ae0fda855030e6691cb4de46caeceb1d2f527a57)), closes [#7](https://github.com/optiflowic/blit.nvim/issues/7)
* remove release-as pin from release-please-config.json ([#44](https://github.com/optiflowic/blit.nvim/issues/44)) ([d921a23](https://github.com/optiflowic/blit.nvim/commit/d921a235dc130200d3f2f75f8ce7d51eabb7c5d4)), closes [#43](https://github.com/optiflowic/blit.nvim/issues/43)
* retry a failed Ghostty resize retransmit without a further resize ([#42](https://github.com/optiflowic/blit.nvim/issues/42)) ([df820e6](https://github.com/optiflowic/blit.nvim/commit/df820e65116276600115a7775b7f04bf1fab4712))

## 0.1.0 (2026-07-25)


### Features

* add config module with defaults and merge ([5606e97](https://github.com/optiflowic/blit.nvim/commit/5606e97dd6b3933a8e0c76415c56743b75751258))
* add plugin entrypoint with idempotent setup ([653fdd2](https://github.com/optiflowic/blit.nvim/commit/653fdd21cc1fad3011fa6df22f3fc9caebbc4d86))
* add renderer and health module stubs ([6e21989](https://github.com/optiflowic/blit.nvim/commit/6e21989d065839de33448938e572345fc871b843))
* implement kitty graphics protocol layer ([c224949](https://github.com/optiflowic/blit.nvim/commit/c224949ab59c019f6971fbffcfe0c041e5e7ee25))
* implement renderer placement layer ([1b6d3e6](https://github.com/optiflowic/blit.nvim/commit/1b6d3e69ef0edc2f6694219c3654eebce57db898))


### Bug Fixes

* close cached tty fd in reset_writer ([8a40ae0](https://github.com/optiflowic/blit.nvim/commit/8a40ae06a1b626740d7be66b5b91e2f8f62728b0))
* correct virt_lines column placement and error propagation in renderer ([eeed383](https://github.com/optiflowic/blit.nvim/commit/eeed383d7161cab69ac0b793d1697669e41ae7bf))
* hide image placements when their anchor window's tab is inactive ([#21](https://github.com/optiflowic/blit.nvim/issues/21)) ([e646cda](https://github.com/optiflowic/blit.nvim/commit/e646cdabf6b7a2735b4e5968a2a2980f47d89350))
* resend hide command every redraw pass while a placement stays invisible ([#25](https://github.com/optiflowic/blit.nvim/issues/25)) ([34f16a1](https://github.com/optiflowic/blit.nvim/commit/34f16a10e6f566217a98ea2e646196dd01ed3cc0))
* retransmit cached images on Ghostty after a real terminal resize ([#26](https://github.com/optiflowic/blit.nvim/issues/26)) ([3cccd37](https://github.com/optiflowic/blit.nvim/commit/3cccd37d48f8d4f7174f924526868876343b72c5))
* retransmit still-visible placements on Ghostty after a real resize ([#35](https://github.com/optiflowic/blit.nvim/issues/35)) ([f089fc1](https://github.com/optiflowic/blit.nvim/commit/f089fc13799101296f1d4467063382ba5d1914b3))
* retry destroy_handle's a=d so clear()/clear_all() self-heal on WezTerm ([#29](https://github.com/optiflowic/blit.nvim/issues/29)) ([c4b942e](https://github.com/optiflowic/blit.nvim/commit/c4b942e264291a2947247ac1605441d86c5d099f))
* stale/misplaced image placements around virt_lines changes ([#20](https://github.com/optiflowic/blit.nvim/issues/20)) ([5dcb61c](https://github.com/optiflowic/blit.nvim/commit/5dcb61c324343362c4d06cc6b0a077cbd930d22a))
* validate ids against blit's reserved range before embedding them ([df00938](https://github.com/optiflowic/blit.nvim/commit/df009386a43990ee87611b5429f99a8e455bfbc5))
* validate user argument type in config.merge ([c5c6e1b](https://github.com/optiflowic/blit.nvim/commit/c5c6e1b86a2195bbcd2a334aa7049239aa6cd58a))
