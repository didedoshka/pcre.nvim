# pcre.nvim

`/` search and `:s` substitute with **PCRE2** regex, matched by ripgrep instead
of Vim's regex engine. Lookahead, lookbehind, backreferences, `\d`/`\w`, named
groups — no more `\v`, `\zs`, or escaping parentheses.

Requires Neovim >= 0.10 and `rg` (ripgrep) built with PCRE2 on `$PATH`.

## Install

Nothing is remapped by default: `setup()` registers the `:S` and `:Pcre`
commands and a hook that makes `:noh` clear search highlights. Taking over `/`,
`n`, `N`, and `:s` is your explicit choice:

```lua
-- lazy.nvim
{
    "didedoshka/pcre.nvim",
    config = function()
        local ps = require("pcre")
        ps.setup({
            substitute_abbrev = true, -- typed :s (with any range) becomes :S
        })
        vim.keymap.set("n", "/", ps.search)
        vim.keymap.set("n", "n", ps.next)
        vim.keymap.set("n", "N", ps.prev)
        vim.keymap.set("n", "<leader>p", ps.toggle)
    end,
}
```

Prefer less invasive? Skip the abbreviation and map `<leader>/` instead of `/`.

## Search

`search()` opens a `/` prompt that looks and feels like native search:
incremental highlighting and view scrolling while you type ('incsearch'),
matches highlighted with `Search`/`CurSearch`, jumplist entries, `'wrapscan'`
and `'hlsearch'` respected, shared native search history, `:noh` to clear.

Inside the prompt: `<CR>` accept (empty pattern repeats the last search),
`<Esc>`/`<C-c>` cancel, `<Left>`/`<Right>` move the cursor, `<BS>`, `<C-u>`
clear to start, `<C-w>` delete word, `<C-r>{reg}` insert register
(`<C-r><C-w>` word under cursor, `<C-r><C-a>` WORD), `<Up>`/`<Down>`/`<C-p>`/
`<C-n>` history.

`next()`/`prev()` (`n`/`N`) re-run the pattern, so they stay correct after
edits; with no pcre search active they fall through to native `n`/`N` (so `*`
and `#` keep working).

Only one search is live at a time. Accepting a pcre search puts the pattern in
`@/` and turns vim's own highlighting off; a later native search (`*`, `#`,
`gd`, a plugin's `search()`) overwrites `@/`, and that is how `n`/`N` know they
have been handed back — they fall through to native and drop the pcre
highlights. That check happens when `n`/`N` next run, so map `*` and `#` to
clear first if you want the old highlights gone the moment you press them:

```lua
vim.keymap.set("n", "*", function() ps.clear(); return "*" end, { expr = true })
```

Case is PCRE2's: sensitive by default, `(?i)` inline flag to ignore.

## Substitute

```
:[range]S/pattern/replacement/flags
```

Vim semantics on a PCRE2 engine: range defaults to the current line, any
non-alphanumeric separator works (`:S#a/b#c#`), and it plugs into 'inccommand'
so you get the same live preview (and preview split) as native `:s`.

Flags: `g` — every match on each line, not just the first; `c` — confirm each
replacement (`y`/`n`/`a`/`q`/`l`); `i` — ignore case.

Replacement syntax: `$1` or `\1` for groups, `${name}` for named groups, `$0`
for the whole match, `$$` for a literal `$`. (`$1X` is safe — it is normalised
to `${1}X` before rg sees it, so it never silently means a group named `1X`.)

With `substitute_abbrev = true`, typing `:s/`, `:%s/`, `:'<,'>s/`, `:12,34s/`
expands to `:S/` as you type. (Not a real `cnoreabbrev`: vim abbreviations
never fire after a range — `:s/` expands but `:%s/` doesn't — so the rewrite
runs on `CmdlineChanged` when the separator is typed.) Native `:s` stays
reachable as `:su`, and a bare `:s<CR>` (no separator) is still native too.

## Toggle

`:Pcre` (or `toggle()`) turns pcre off and back on — it echoes `pcre off` /
`pcre on` — so the
same pattern can be run through Vim's own engine without editing the config —
handy for seeing exactly where the two engines differ. While off, `/` opens the
native prompt, `n`/`N` are native, and a typed `:s` is not rewritten; `:S` keeps
substituting with PCRE2, so the two are comparable side by side. Toggling off
also drops the live pcre search and its highlights. `enabled()` reports the
state, for a statusline.

## Not covered (by design or not yet)

- Normal mode only: `/` in visual/operator-pending mode, and `?`, stay native.
- No search offsets (`/foo/e`), no `gn`/`cgn` (they read `@/` with Vim's own
  regex engine, so a pcre-only pattern means something else to them).
- `:g/pat/s//` runs native `:s` — the rewrite only fires at command start.
- Ranges with named marks (`:'a,'bs/`) are not rewritten — type `:'a,'bS/`.
- A replacement that expands across multiple lines is rejected.
- Patterns are single-line (no `--multiline`).
