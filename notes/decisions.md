# Decisions

Dated log of the non-obvious choices and what forced them. Measured traps live
here too — "measured" means verified in this repo, not recalled from docs.
Shipped behaviour belongs in the readme, not here.

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
- Deviations from native, accepted: case stays PCRE2's (native `*` follows
  'ignorecase'), and with the cursor on whitespace before a word, we land on
  that word where native skips past it to the following occurrence.

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
