# Decisions

Dated log of the non-obvious choices and what forced them. Measured traps live
here too — "measured" means verified in this repo, not recalled from docs.
Shipped behaviour belongs in the readme, not here.

## 2026-08-06 — the current match is an extmark, not coordinates

`live.cur` was the match the search landed on, frozen as `{lnum, scol, ecol}`,
and paint() drew `CurSearch` over that span unconditionally. Insert at the
cursor right after a search and the highlight sat on the text being typed —
the reported bug — or on whatever else landed there, matching or not.

Measured against a real nvim (PTY, `nvim__inspect_cell` backgrounds), native
after `/needle<CR>` then `i` + typing `needle`: the typed cells are plain
`Search` and `CurSearch` is on the original match, pushed right. So the
current match follows the text. An extmark with the default right gravity
reproduces that exactly, and `CurSearch` is now painted only when the find
still reports a match starting at the anchor.

- Remaining divergence, deliberate: appending at the end of the line (`A`) drops
  native's `CurSearch` entirely, though nothing touched the match. Ours keeps
  it. `:h hl-CurSearch` says the highlight "may get outdated if changes are
  made", so neither reading is wrong, and following the text is the useful one.

## 2026-08-06 — the prompt fires WinScrolled itself

Measured in a PTY: typing `/getregion` scrolls the view either way, but native
incsearch fires WinScrolled 3 times while typing and our prompt 0 — nvim only
triggers it "back in the main loop", and `vim.fn.input()` never gets there. So
every viewport-driven consumer saw the scrolled-in lines only after `<CR>`;
LSP semantic tokens are the visible one, their range request hangs off exactly
that event (`vim/lsp/semantic_tokens.lua`, 200 ms debounce).

- `nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })` reaches all
  three flavours of registration — plain, buffer-local (what semantic tokens
  uses) and win-id pattern. Passing `buffer =` instead misses the win-id one.
- Measured trap: `v:event` stays an empty dict, `data` does not fill it. A
  consumer reading `v:event.all.topline` errors, so the call is pcall'd — an
  error must not take the prompt down.
- The async half works: a reply arriving 200 ms later, while `input()` is
  still blocked, redraws through `nvim__redraw` and lands on the screen
  (verified with a fake range-highlighter over the real prompt).

## 2026-07-30 — versions mark releases, not working sessions

Eight tags landed in one day (v0.1.1–v0.1.8), one per fix-and-verify cycle —
commit markers, not versions. Nobody could have installed them: no remote,
never published. Collapsed into a single v0.1.1 (tags deleted locally,
commits untouched; the changelog sections merged) — a z-bump, since nothing
breaks an existing setup, and parity is not complete enough for a v0.2.0.
The rule going forward: while unpublished, tag once per coherent milestone —
a day's worth of work at most — and after publication, tag only what users
should update to.

## 2026-07-30 — live preview for the typed :s: extmarks, never buffer edits

The "enter" mode needed its own 'inccommand': while the line says `:s`, the
native preview machinery runs the native engine, and there is no hook to
replace a builtin command's preview. Reimplementation candidates, measured:

- Buffer-edit + `undojoin` revert works (tree stable across cycles, u/C-r
  correct; E790 only right after an undo, pcall-able) but touches real text:
  marks and other plugins' extmarks would drift on every keystroke. Kept as
  the documented fallback.
- Winner: never touch the buffer. Each pending edit renders as an extmark
  `conceal = ""` over the match plus inline `virt_text` with the expansion.
  Measured under a PTY: the screen draws `XY bar LONGER end` for
  shorter *and* longer replacements, exactly like the real edit, including
  with the cmdline open. Undo, marks, 'modified', changedtick: untouched by
  construction.
- Native 'inccommand' must be parked or it edits the buffer for real
  underneath — and the parking must happen at **CmdlineEnter**: once the
  native preview has engaged, writing the option raises E474. Measured only
  in a real UI (battle-testing found it): a bare `:s` with a previous
  substitute is already previewable, so the machinery engages one keystroke
  before the first separator; headless never engages it, which hid this from
  the suite. Unparked at CmdlineLeave (pcall + scheduled retry). While
  parked, live_preview covers a directly typed :S too, since the official
  :S preview can't run.
- Pattern phase, measured (battle-testing found the deviation on a visual
  range): native highlights only the matches that WOULD be substituted —
  first per line without /g — not every match, and the group is
  `hl-Substitute`, disambiguated from Search by giving it a unique color and
  reading the cell with nvim__inspect_cell (they share colors in the default
  scheme). So the pattern phase renders compute()'s edits, not find()'s
  matches. screenstring-based parity misses this class entirely; the manual
  tier compares screenattr *shapes* (per-row first-appearance letters) too.
- `inccommand=split`'s preview window is not reproduced; matches on screen
  are the preview.
- Measured trap (tests): feedkeys("x") force-closes a drained cmdline like
  <Esc>, so mid-session state must be asserted from a CmdlineChanged
  autocmd registered after the plugin's, never after feedkeys returns.
- The after-<CR> screen, measured against native cell by cell (PTY job +
  RPC probes, tests/drivers not in the offline suite): native's report
  threshold is the *substitution count*, not the line count (3 subs on 1
  line reports at report=2); the report must be a history message or the
  next redraw repaints the leftover cmdline over it; and below the
  threshold the row must show the *typed* :s line — the run() repaints it,
  or the swapped :%S would sit there. With those three, every stage
  (pattern, replacement, /g, <Esc>, <CR> reported and quiet) renders
  identically to native.

## 2026-07-30 — :s stays :s on screen (the "enter" abbrev mode)

Measured: setcmdline() inside CmdlineLeave still changes what executes, so
the :s → :S swap can happen at the <CR> and never be visible — the cmdline
shows the typed :s all along. Two measured consequences, both handled or
declared:

- The : history records the *swapped* line; the hook drops it and re-adds
  the typed one (vim.schedule, after the command has run).
- While typing, 'inccommand' previews native :s reading a pcre pattern —
  harmless (no errors, buffer intact, measured) but it is the wrong
  engine's preview. `substitute_abbrev = true` keeps the visible swap and
  the true pcre preview; the mode is a taste knob, not a replacement.

## 2026-07-30 — the remaining search contexts: ?, visual, o-pending, gn/gN, v_*

The mechanics were all measured before coding, and they made this far
cheaper than feared:

- `vim.fn.input()` inside a visual-mode mapping keeps the selection alive:
  the prompt extends it live while typing, nothing to save or restore.
- In an operator-pending lua mapping, moving the cursor IS the motion
  (exclusive, like native d/), and input() works there too — no g@ dance.
- An o-pending mapping that makes a charwise visual selection has the
  operator apply to it inclusively, and `.` re-fires the mapping — exactly
  cgn's contract, so dot-repeat walks successive matches for free.
- Native gn selects the covering match, anchor on its start; gN mirrors it,
  anchor on the end. In visual mode both move the cursor to the far edge
  strictly past it (a cursor already on an edge goes to the next match).
- v_* is an nvim default (literal \V pattern, from the selection start,
  selection dropped). A multi-line selection is native-supported (\Vab\nc)
  but refused here: the engine matches line by line — the standing scope cut.
- Measured trap: v:count persists after a completed `:normal` command — a
  direct search_selection() call right after `normal! v2l` still sees
  count=2 and jumps twice. Only test code can hit this; a real mapping's
  count is its own.

## 2026-07-30 — native-parity audit: fixed or declared, all measured

Systematic pass comparing /, n/N, the star family and :S against native.
Fixed to match native (each behaviour measured before coding):

- Direction: a backward search (`#`) makes n continue backward and N
  forward, the echo shows `?pat`, and v:searchforward mirrors it.
- `[count]/pat` and `[count]n` take the count'th match.
- `<C-g>`/`<C-t>` cycle the current match while typing ('incsearch' only);
  accepting lands on the cycled match. Native's end-of-buffer wrap for
  these was not headless-measurable (feedkeys swallows the keys mid-prompt),
  so the semantics follow :h c_CTRL-G: 'wrapscan' applies.
- While typing, the current match paints IncSearch (not CurSearch), and
  with 'nohlsearch' only the current match paints, like native incsearch.
- Wraps echo a right-aligned `W [x/y]` and no warning line; with
  'shortmess' S the warning line comes back, and s silences it too.
  SearchWrapped fires on every wrap.
- `<C-r><C-l>` inserts the line under the cursor.
- :S mirrors :s around the search state: owns @/ even when nothing matched,
  relights highlights, n/N repeat it, the search history stays untouched;
  the cursor ends on the first non-blank of the last substituted line;
  `:S//x/` reuses the last pcre pattern; 'gdefault' inverts /g.

Deviations that remain, deliberate:

- Case is PCRE2's, `(?i)` inline (native / and * follow 'ignorecase') — the
  2026-07-20 decision stands.
- No search offsets (`/pat/e`): the whole prompt input is the pattern, so
  `/` needs no escaping in it; adopting native's `\/` termination to make
  room for offsets is a breaking change. Undecided, awaiting a real need.
- :s flags beyond g/c/i (n, e, I, &, r) and the repeat family (`&`, `g&`,
  bare `:s`) are not implemented.
- Scope cuts stand: `?`, visual and operator-pending `/`, `gn`/`cgn`,
  multi-line patterns.

- Measured trap: nvim's default `<C-l>` runs `<Cmd>nohlsearch|...`, and a
  `<Cmd>` mapping fires no Cmdline* events, so the :noh hook cannot see it —
  pcre highlights survive a `<C-l>`. Unhookable plugin-side; a config that
  uses `<C-l>` must chain pcre.clear() into its own mapping.
- Measured trap: in the offline suite, a typed `:S` only exists after some
  test has called `ps.setup()` (line ~810); :S tests placed earlier must
  call `ps.setup({})` themselves or the E492 is silently swallowed by
  feedkeys and the buffer just stays unchanged.

## 2026-07-30 — the star family is pcre too

A native `*` flipped the session between two regex syntaxes: `@/` and the
history held `\<word\>`, and the next `/` spoke PCRE again. `search_cword()`
keeps it one language — the pattern is built from `<cword>` (`\bword\b`,
g-variants bare, metacharacters escaped), owns `@/`, and shares n/N's jump
path.

- `\b` goes only where the edge char is a word char *to PCRE2*: 'iskeyword'
  can put chars in `<cword>` that `\w` does not cover (a lisp `-`, a `!`),
  and `\b` against a non-word edge demands a word char *outside* the match —
  the word would never match itself. pcre2 probes its own `\w` (`^\w`/`\w$`
  against the word), not a Lua guess: UTF+UCP make it unicode-aware.
- The only deviation from native, accepted: case stays PCRE2's (native `*`
  follows 'ignorecase').
- Measured trap: native `*`/`#` search from the *start of the word*, not from
  the cursor — `*` on the whitespace before a word skips that word, `#` from
  mid-word skips the current occurrence. So the jump origin is the match
  covering-or-after the cursor on its line, not the cursor position.

## 2026-07-26 — versioning: SemVer 0.x

While `0.y.z`, breaking bumps `y`, everything else bumps `z`. `1.0.0` is
deferred until the plugin survives real interactive use — a major-version
history for a plugin nobody could install yet would be noise.

## 2026-07-23 — the prompt runs on the real cmdline

Two attempts at a hand-rolled `getcharstr()` prompt loop failed the same way:
an echoed caret cell neither blinks nor takes the `guicursor` shape, and with
`'incsearch'` the real cursor sitting on the match made two visible cursors.
So the prompt is `vim.fn.input()` + `CmdlineChanged`, and nvim itself provides
cursor, editing keys, and paste. Only three things are remapped for the
prompt's lifetime: history keys (`input()` uses "@" history, not search
history), `<C-r>` register insertion with newline flattening, and `<BS>` past
empty to leave the search.

- Measured trap: a mapped `<Esc>` in the cmdline *executes* the command
  instead of cancelling (`:h c_<Esc>`) — cancel must go through `<C-c>`.
- Measured trap: tests must `feedkeys` with the `t` (typed) flag, or `<Esc>`
  accepts and the temporary cmdline maps never fire.

## 2026-07-23 — backend: in-process libpcre2 over LuaJIT FFI, rg deleted

"One backend will do." The rg subprocess cost ~5.5 ms spawn per keystroke and
needed two passes for capture groups (`--json` carries no group spans). FFI
`pcre2_substitute` with `MATCHED | REPLACEMENT_ONLY` expands the replacement
against live match data in one pass. Measured: FFI find-all beats
`matchbufline()` at every corpus size (65 ms vs 411 ms worst case).

- Constants are hardcoded from `pcre2.h` (no header on typical boxes) and
  verified behaviorally by the suite.
- `match_limit`/`depth_limit` keep mid-typing backtracking bombs at ~0.1 ms.
- Measured trap: cdefs must use `const char*`, never `uint8_t*` — LuaJIT only
  auto-converts Lua strings to char pointers.
- Full sonames in the `ffi.load` list: Linux ships only the versioned
  `.so.0` (no `-dev` symlink), and `/opt/homebrew/lib` is not in dlopen's
  default path on arm64 macs.

## 2026-07-23 — highlights: matchaddpos, viewport-only

Measured with PTY `screenattr` probes: sign `linehl` beats char extmarks at
any priority, but `matchaddpos()` lives in the same stage as native hlsearch
and layers exactly like it — over a sign's line background, under a visual
selection. So highlights are matchaddpos per window, viewport-only, repainted
on `WinScrolled`/`WinResized`/`BufEnter`/`TextChanged{,I}`.

- Measured trap: sign groups ARE extmark namespaces — `sign_place()` group
  "x" and `nvim_create_namespace("x")` collide; `clear_namespace` deletes the
  sign.

## 2026-07-20 — search ownership via `@/`

nvim fires no event for a search, so `@/ ~= owned_pattern` is the only signal
that a native search (`*`, `#`, `gd`, a plugin) took over. Accepting a pcre
search writes the pattern to `@/` and sets `v:hlsearch = 0`; `n`/`N` check
ownership when they run and fall through to native.

- Measured trap: `setreg("/")` itself turns native highlighting back on — the
  order must be setreg first, then `v:hlsearch = 0`.

## 2026-07-20 — `:s` rewrite on CmdlineChanged, not cnoreabbrev

Measured trap: Vim abbreviations never fire after a range — `:s/` expands but
`:%s/` doesn't. So the opt-in `:s` → `:S` expansion is a `CmdlineChanged` +
`setcmdline()` rewrite that fires when the separator is typed. Native escape
hatch: `:su`; named-mark ranges (`:'a,'b s`) are left alone.

## 2026-07-20 — case sensitivity is PCRE2's

Always case-sensitive, `(?i)` inline to ignore. No smart-case: undecided
whether it's wanted, and it's easy to add later — the reverse is a breaking
change.

## 2026-07-20 — n/N re-run the pattern

No cached positions: `n`/`N` re-match, so they stay correct after buffer
edits — native `n` re-evaluates the pattern too.

## 2026-07-20 — scope cuts

Normal mode only; `?`, visual/operator-pending `/`, `gn`/`cgn` stay native
(`gn` reads `@/` with Vim's own engine — a pcre-only pattern means something
else to it). Patterns are single-line. Multi-line replacements are rejected.

## 2026-07-20 — tests run under `nvim -l`, not `:luafile`

Measured: under `luafile` a Vim error raised inside `vim.fn.*` does not
surface as a Lua error — the call returns `""` and the suite can't see it.
Under `-l` it propagates and the test fails. One nvim process per spec file:
last-pattern state is process-global.
