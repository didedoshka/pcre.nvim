# Changelog

Versions follow SemVer, pre-1.0 flavour: while `0.y.z`, a breaking change bumps
`y`, everything else bumps `z`. `1.0.0` will mark the API as stable.

## v0.1.0 — 2026-07-26

The engine moved in-process: the rg subprocess is gone, matching now happens in
libpcre2-8 over LuaJIT FFI. Faster than Vim's native engine at every corpus
size measured (see `benchmarks/bench-results.md`); the ~5.5 ms per-keystroke
spawn floor dropped to ~0.

- `search()` prompt reworked onto the real cmdline (`vim.fn.input()`): native
  cursor blink and shape, native cmdline editing; search history and `<C-r>`
  register insertion (`<C-r><C-w>`, `<C-r><C-a>`) wired in.
- Match count echoes right-aligned as `[cur/total]` on accept, never while
  typing — like native.
- `'incsearch'` respected: with `noincsearch` nothing moves, paints or counts
  until `<CR>`.
- Terminal paste while the prompt is open lands in the pattern, newlines
  flattened to spaces.
- Highlights now layer exactly like native hlsearch — over a sign's line
  background, under a visual selection.
- MIT license, CI (Linux stable + 0.10, macOS).

## v0.0.2 — 2026-07-22

- `:Pcre` toggle: turn pcre off and back on at runtime; `:S` stays available
  while off, so the two engines can be compared side by side.
- Benchmark harness (`tests/bench.lua`) comparing find-all against Vim's
  native engine.

## v0.0.1 — 2026-07-20

Initial version: `/` search and `:S`/`:s` substitute matched by PCRE2 through
an `rg --pcre2` subprocess. Incremental highlighting, `[cur/total]` count,
search ownership handoff to native `*`/`#`/`gd`, `'inccommand'` preview for
`:S`, opt-in `:s` → `:S` rewrite, headless test suite.
