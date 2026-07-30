# Changelog

Versions follow SemVer, pre-1.0 flavour: while `0.y.z`, a breaking change bumps
`y`, everything else bumps `z`. `1.0.0` will mark the API as stable.

## v0.1.1 — 2026-07-30

The native search surface in PCRE, one release for one day of development
(eight working tags, never published, collapsed into this one). Parity is
not complete yet — search offsets, the remaining :s flags (`n`, `e`, `I`,
the `&`/`g&` repeat family) and multi-line patterns stay open.

- Star family: `search_cword({ backward?, exact? })` searches the word under
  the cursor as `\bword\b` (boundaries only where the edge is a PCRE2 word
  char), jumping from the word start like native `*`/`#`; `g*`/`g#` skip the
  boundaries.
- Directions and counts everywhere: after `#` or `?`, `n` continues backward
  and `N` forward (`v:searchforward` mirrored); `[count]/pat`, `[count]n`,
  `[count]*` all work.
- The prompt grew `?` (backward search), `<C-g>`/`<C-t>` match cycling,
  IncSearch on the current match while typing (only it under 'nohlsearch'),
  `<C-r><C-l>`, the native wrap echo (`W [x/y]`, 'shortmess' S/s matrix) and
  the SearchWrapped autocmd.
- Visual and operator-pending `/` and `?`: the prompt extends a selection
  live, and the accepted jump is the operator's motion. `gn`/`gN` select the
  match under or next to the cursor — `cgn` + `.` walks matches like native.
  Visual `*`/`#` search the selection literally (multi-line refused).
- `:S` handles the search state like `:s`: owns `@/` (even on no match),
  relights highlights, leaves the search history alone, ends on the first
  non-blank, reports by substitution count; `:S//x/` reuses the last pcre
  pattern and `'gdefault'` inverts `/g`.
- `substitute_abbrev = "enter"`: a typed `:s` looks native end to end — the
  swap to `:S` happens invisibly at `<CR>`, the `:` history and the
  after-run screen keep the typed line, and a live PCRE preview renders
  while typing without ever touching the buffer (conceal + inline
  virt_text; undo, marks and 'modified' untouched by construction). The
  pattern phase highlights exactly the pending substitutions, like native.
- Manual verify tier `tests/screen_parity.lua`: drives real interactive
  nvims in a PTY and compares screens and highlight shapes against native,
  cell by cell.

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
