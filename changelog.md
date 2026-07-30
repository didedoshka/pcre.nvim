# Changelog

Versions follow SemVer, pre-1.0 flavour: while `0.y.z`, a breaking change bumps
`y`, everything else bumps `z`. `1.0.0` will mark the API as stable.

## v0.1.6 — 2026-07-30

- The "enter" abbrev mode now has a live PCRE preview while the `:s` is being
  typed — the missing half of v0.1.5. The buffer is never edited: matches
  conceal under inline virt_text carrying their expansion (drawn exactly like
  the real replacement — PTY-verified), so undo, marks and 'modified' cannot
  be affected. Pattern phase highlights matches; the replacement phase
  respects `/g`, `/i`, `'gdefault'` and `:s//`. Native `'inccommand'` is
  parked for the session and restored on leave. `inccommand=split`'s extra
  preview window is not reproduced (nosplit-style only).

## v0.1.5 — 2026-07-30

- `substitute_abbrev = "enter"`: the typed `:s` swaps to `:S` only at `<CR>`,
  inside CmdlineLeave — the cmdline never shows the rewrite and the `:`
  history keeps exactly what was typed. The trade: while typing, the
  `'inccommand'` preview is the native engine's reading of the pattern.
  `substitute_abbrev = true` keeps the visible swap and the true pcre
  preview.

## v0.1.4 — 2026-07-30

The remaining native search contexts, all PCRE now — multi-line patterns
stay the one scope cut:

- `?`, the backward prompt: `search({ backward = true })`. Counts, n/N
  direction, `<C-g>`/`<C-t>` (cycling backward, like native), the W [x/y]
  echo — everything mirrored.
- Visual `/` and `?` extend the selection to the match, live while typing.
- Operator-pending `/` and `?`: `d/pat<CR>` is an exclusive motion, native
  semantics in both directions.
- `gn`/`gN` (`select_match({ backward? })`): select the covering match, else
  the next in the search direction; in visual mode extend to the match edge;
  `cgn` + `.` walks successive matches exactly like native. Falls through to
  native gn/gN when no pcre search is owned.
- Visual `*`/`#` (`search_selection({ backward? })`): literal search for the
  selection, like nvim's default v_*, pcre-escaped; a multi-line selection
  is refused.

## v0.1.3 — 2026-07-30

Native-parity batch — every behaviour measured against nvim first:

- Backward searches set the direction: after `#`, `n` continues backward and
  `N` forward, the echo shows `?pat`, and `v:searchforward` mirrors it.
- `[count]/pat`, `[count]n` and `[count]*` work.
- `<C-g>`/`<C-t>` cycle the current match while typing (`'incsearch'`);
  accepting lands on the cycled match.
- While typing, the current match highlights as IncSearch, and with
  `'nohlsearch'` only the current match is painted — like native.
- A wrapped search echoes a right-aligned `W [x/y]` instead of the warning
  line; the `'shortmess'` S and s flags are respected; the SearchWrapped
  autocmd fires.
- `<C-r><C-l>` inserts the line under the cursor into the pattern.
- `:S` handles the search state like `:s`: `@/` is set (even when nothing
  matched), highlights relight, `n`/`N` repeat the pattern, the search
  history stays untouched. The cursor ends on the first non-blank of the
  last substituted line. `:S//x/` reuses the last pcre pattern, and
  `'gdefault'` inverts `/g`.

Known trap: nvim's default `<C-l>` clears native hlsearch through a `<Cmd>`
mapping no Cmdline event can observe — chain `require("pcre").clear()` into
your own `<C-l>` mapping if you use it.

## v0.1.2 — 2026-07-30

- Star family parity fix: native `*`/`#` search from the start of the word,
  not from the cursor (measured — `*` on the whitespace before a word skips
  that word, `#` from mid-word skips the current occurrence). `search_cword`
  now does the same; only the regex syntax differs from native.

## v0.1.1 — 2026-07-30

- Star family: `search_cword({ backward?, exact? })` searches the word under
  the cursor as a PCRE pattern (`\bword\b`; `exact = false` is the `g*`
  flavour, no boundaries), so `*`/`#`/`g*`/`g#` can speak the same regex
  syntax as `/` instead of handing `@/` to the native engine. `\b` is added
  only where the word's edge is a PCRE2 word char, metacharacters are
  escaped, and while `:Pcre`-toggled off the mapping falls through to the
  native key.
- `n`/`N` and the star family accept a count (`3n`), including the native
  fallthrough.

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
