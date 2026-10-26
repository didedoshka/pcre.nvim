# pcre.nvim — session rules

`/` search and `:s` substitute with PCRE2, matched in-process by libpcre2-8
over LuaJIT FFI. Personal plugin, loaded from this checkout via lazy.nvim;
being prepared for publication.

## Layout

- `lua/pcre/init.lua` — `setup(opts)`, public functions, `:S`/`:Pcre` commands.
- `lua/pcre/pcre2.lua` — the FFI binding; constants hardcoded from `pcre2.h`,
  verified behaviorally by the suite.
- `lua/pcre/search.lua` — the `/` prompt, highlights, `n`/`N`, ownership.
- `lua/pcre/substitute.lua` — `:S`, 'inccommand' preview, the `:s` rewrite.
- `tests/` — offline suite + `bench.lua`, plus the manual tier
  `screen_parity.lua` (PTY-driven real UI vs native, ~40 s — see Verify).
  `notes/decisions.md` — dated log of non-obvious choices and measured
  traps; append an entry for each new one.
- `changelog.md` — user-facing history, SemVer 0.x: breaking bumps minor,
  everything else bumps patch; `1.0.0` when battle-tested. Keep it current
  with behaviour changes; tag releases `vX.Y.Z` (annotated).

## Invariants

- Neovim >= 0.10, LuaJIT build. Only external dependency is `libpcre2-8`;
  if it (or FFI) is missing, `setup()` notifies once and leaves everything
  native — never a hard error.
- Nothing is remapped by default; taking over `/`, `n`, `N`, `:s` is the
  user's explicit config choice.
- No new UI: the prompt is the real cmdline, results surface through native
  highlighting and echoes.

## Verify & workflow

- `tests/run.sh` after any Lua change: lua-language-server `--check` (run
  from repo root or `.luarc.json` isn't found; baseline zero problems) + the
  headless suite under `nvim -l`. lua-ls does not catch cross-module
  breakage; only the suite does.
- `nvim --headless --clean -l tests/screen_parity.lua` after anything
  touching the cmdline, previews or messages: drives real interactive nvims
  in a PTY and compares screens against native. Headless cannot see this
  class of bug — cmdpreview never engages there (the E474 regression), and
  message retention only shows on a real screen. ~40 s, needs a PTY; not in
  run.sh or the edit hook.
- Commit each verified change without asking (`area: lowercase summary`). Never rewrite
  history — no amend, rebase, or reset past a commit; fix forward.
- **`readme.md` is the user's.** They write it themselves — never draft,
  edit, or "improve" it. After a behaviour change, list which readme
  sections went stale so they can update them.

## Style

4-space indent, double quotes, ~100 cols (enforced by `.luarc.json` format
config — no stylua). Comments explain *why* — a measured trap, a service
quirk — never what the next line does.
