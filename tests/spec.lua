-- Offline suite: loads every module for real (lua-ls does not catch
-- cross-module breakage) and drives the FFI-backed logic against scratch
-- buffers. The prompt is driven for real too: keys stuffed into the typeahead
-- before search() are what the cmdline (vim.fn.input) consumes, so these
-- tests exercise the same code path as interactive typing.
-- Offline; no network, no user config.
local failed = 0

local function t(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("  ok    " .. name)
    else
        failed = failed + 1
        print("  FAIL  " .. name .. ": " .. tostring(err))
    end
end

local function eq(got, want)
    assert(vim.deep_equal(got, want),
        ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)))
end

local function buf_with(lines)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
end

local function lines_of(b)
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- current buffer + cursor, for tests that drive cursor movement
local function show(lines, cursor)
    local b = buf_with(lines)
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
    return b
end

local function cursor()
    return vim.api.nvim_win_get_cursor(0)
end

-- simplified matchaddpos() items of the windows showing b, in buffer order:
-- { {row, col, end_col, hl}, ... } (0-based, like the old extmark shape)
local function search_marks(b)
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == b then
            for _, m in ipairs(vim.fn.getmatches(win)) do
                for i = 1, 8 do
                    local p = m["pos" .. i]
                    if type(p) == "table" then
                        out[#out + 1] = { p[1] - 1, p[2] - 1, p[2] - 1 + p[3], m.group }
                    end
                end
            end
        end
    end
    table.sort(out, function(x, y)
        return x[1] < y[1] or (x[1] == y[1] and x[2] < y[2])
    end)
    return out
end

local function type_keys(keys)
    -- "t": handled as typed -- a mapped <Esc> in the cmdline would act like <CR>
    -- (:h c_<Esc>), and the prompt's own temporary c-mode maps must fire
    vim.fn.feedkeys(vim.keycode(keys), "t")
end

local search = require("pcre.search")
local sub = require("pcre.substitute")
local ps = require("pcre")

-- find ------------------------------------------------------------------------

t("find: positions and multiple matches per line", function()
    local b = buf_with({ "foo bar", "baz foo42 foo" })
    eq(search.find(b, [[foo\d*]]), {
        { lnum = 1, scol = 0, ecol = 3 },
        { lnum = 2, scol = 4, ecol = 9 },
        { lnum = 2, scol = 10, ecol = 13 },
    })
end)

t("find: pcre2 lookahead works", function()
    local b = buf_with({ "foo1 foo2" })
    eq(search.find(b, [[foo(?=2)]]), { { lnum = 1, scol = 5, ecol = 8 } })
end)

t("find: multibyte lines give byte offsets", function()
    local b = buf_with({ "π = x", "héllo wörld" })
    eq(search.find(b, [[=]]), { { lnum = 1, scol = 3, ecol = 4 } })
    eq(search.find(b, [[wörld]]), { { lnum = 2, scol = 7, ecol = 13 } })
end)

t("find: zero-width matches (pure lookahead)", function()
    local b = buf_with({ "foo" })
    eq(search.find(b, [[(?=o)]]), {
        { lnum = 1, scol = 1, ecol = 1 },
        { lnum = 1, scol = 2, ecol = 2 },
    })
end)

t("find: no matches is an empty list", function()
    local b = buf_with({ "nothing here" })
    eq(search.find(b, "xyzzy"), {})
end)

t("find: bad pattern reports the PCRE2 error", function()
    local b = buf_with({ "a" })
    local matches, err = search.find(b, "(?=")
    assert(matches == nil and err and err:find("PCRE2"), err)
end)

-- prompt loop -----------------------------------------------------------------
-- Order matters here: the native-fallthrough test must run before anything
-- accepts a search, because accepting sets the module's last-pattern state.

t("n with no pcre search yet falls through to native n", function()
    show({ "aaa", "bbb" }, { 1, 0 })
    ps.next() -- native n with no previous pattern: E35, echoed not thrown
    eq(cursor(), { 1, 0 })
end)

t("search: jumps to first match after cursor, highlights all, one CurSearch", function()
    local b = show({ "alpha foo1", "beta", "gamma foo22" }, { 1, 0 })
    type_keys("foo[0-9]+<CR>")
    ps.search()
    eq(cursor(), { 1, 6 })
    eq(search_marks(b), {
        { 0, 6, 10, "CurSearch" },
        { 2, 6, 11, "Search" },
    })
end)

t("search: strictly after -- cursor on a match start goes to the next one", function()
    show({ "foo foo" }, { 1, 0 })
    type_keys("foo<CR>")
    ps.search()
    eq(cursor(), { 1, 4 })
end)

t("search: <Esc> cancels, restores cursor, clears highlights", function()
    local b = show({ "xx", "yy foo" }, { 1, 1 })
    type_keys("foo<Esc>")
    ps.search()
    eq(cursor(), { 1, 1 })
    eq(search_marks(b), {})
end)

t("search: <BS> edits the pattern", function()
    show({ "foo2 bar", "foo22" }, { 1, 0 })
    type_keys("foo2x<BS><CR>") -- typo, backspace, accept "foo2"
    ps.search()
    -- the line-1 match starts at the cursor column, so strictly-after skips it
    eq(cursor(), { 2, 0 })
end)

t("search: <C-u> clears the pattern", function()
    show({ "zzz foo" }, { 1, 0 })
    type_keys("zzz<C-u>foo<CR>")
    ps.search()
    eq(cursor(), { 1, 4 })
end)

t("search: <C-w> deletes the last word", function()
    show({ "a foo b" }, { 1, 0 })
    type_keys("bar<C-w>foo<CR>")
    ps.search()
    eq(cursor(), { 1, 2 })
end)

t("search: <Left> moves the cursor so typed text inserts mid-pattern", function()
    show({ "abcX", "abXc" }, { 1, 0 })
    type_keys("abc<Left>X<CR>") -- "abc", cursor back one, insert X -> "abXc"
    ps.search()
    eq(cursor(), { 2, 0 })
end)

t("search: <Left> then <BS> deletes the character before the cursor, not the last one", function()
    show({ "ac" }, { 1, 0 })
    type_keys("abc<Left><BS><CR>") -- "abc", cursor back one, backspace drops the "b" -> "ac"
    ps.search()
    eq(cursor(), { 1, 0 })
end)

t("search: <Right> moves the cursor back toward the end", function()
    show({ "abcd" }, { 1, 0 })
    type_keys("ac<Left>b<Right>d<CR>") -- "ac" -> "abc" (insert mid) -> "abcd" (append at end again)
    ps.search()
    eq(cursor(), { 1, 0 })
end)

-- the prompt runs on the real cmdline (vim.fn.input), so the cursor in it is
-- the native one -- blink and guicursor shape can't be asserted headless (they
-- live in the terminal), but the cmdline type and cursor position can; full
-- keystroke-parity against native "/" is in spec_parity.lua
t("search: the prompt is a real cmdline and <Left> moves its cursor", function()
    show({ "abc" }, { 1, 0 })
    local sampled = {} -- { cmdtype, cmdline, cmdpos } at each change
    local group = vim.api.nvim_create_augroup("pcre.test.cmdline", { clear = true })
    vim.api.nvim_create_autocmd("CmdlineChanged", {
        group = group,
        callback = function()
            sampled[#sampled + 1] =
                { vim.fn.getcmdtype(), vim.fn.getcmdline(), vim.fn.getcmdpos() }
        end,
    })
    type_keys("ab<Left><Esc>")
    ps.search()
    vim.api.nvim_del_augroup_by_id(group)
    -- <Left> alone fires no CmdlineChanged; the "b" insert shows pos 3, and
    -- the sampled type is "@" (input()), a real cmdline
    eq(sampled, { { "@", "a", 2 }, { "@", "ab", 3 } })
    eq(cursor(), { 1, 0 }) -- cancelled
end)

t("search: <C-u> after <Left> clears only up to the cursor", function()
    show({ "cd" }, { 1, 0 })
    type_keys("abcd<Left><Left><C-u><CR>") -- cursor between b and c, clear "ab", keep "cd"
    ps.search()
    eq(cursor(), { 1, 0 })
end)

t("search: <C-w> after <Left> deletes the word before the cursor, keeping text after it", function()
    show({ "nomatch", "xbary" }, { 1, 0 })
    type_keys("foo bar<Left><Left><Left><C-w><CR>") -- cursor before "bar", C-w drops "foo "
    ps.search()
    eq(cursor(), { 2, 1 })
end)

t("search: <C-r>{reg} inserts a register, newlines flattened", function()
    show({ "z foo1" }, { 1, 0 })
    vim.fn.setreg("a", "fo")
    type_keys("<C-r>ao1<CR>")
    ps.search()
    eq(cursor(), { 1, 2 })
    show({ "x a b y" }, { 1, 0 })
    vim.fn.setreg("b", "a\nb")
    type_keys("<C-r>b<CR>") -- "a\nb" becomes "a b"
    ps.search()
    eq(cursor(), { 1, 2 })
end)

t("search: <C-r><C-w> inserts the word under the cursor", function()
    show({ "needle x", "needle" }, { 1, 0 })
    type_keys("<C-r><C-w><CR>")
    ps.search()
    eq(cursor(), { 2, 0 }) -- the match at the cursor is not strictly after
end)

t("search: <C-r><C-a> inserts the WORD under the cursor", function()
    show({ "a needle; b", "needle;" }, { 1, 2 })
    type_keys("<C-r><C-a><CR>") -- "needle;" -- cword would stop at the ";"
    ps.search()
    eq(cursor(), { 2, 0 })
end)

t("search: <Up> recalls history", function()
    show({ "qq needle" }, { 1, 0 })
    vim.fn.histadd("search", "needle")
    type_keys("<Up><CR>")
    ps.search()
    eq(cursor(), { 1, 3 })
end)

t("search: empty pattern repeats the last search", function()
    show({ "a", "needle", "needle" }, { 1, 0 })
    type_keys("needle<CR>")
    ps.search()
    eq(cursor(), { 2, 0 })
    type_keys("<CR>")
    ps.search()
    eq(cursor(), { 3, 0 })
end)

t("search: pattern not found restores cursor and highlights", function()
    local b = show({ "abc" }, { 1, 1 })
    type_keys("zzz9<CR>")
    ps.search()
    eq(cursor(), { 1, 1 })
    eq(search_marks(b), {})
end)

t("n/N: wrap both ways", function()
    show({ "m1 x", "y", "m2" }, { 1, 0 })
    type_keys("m[0-9]<CR>")
    ps.search() -- on m1... cursor col 0, match scol 0 not strictly after -> m2
    eq(cursor(), { 3, 0 })
    ps.next() -- wraps to m1
    eq(cursor(), { 1, 0 })
    ps.prev() -- wraps back to m2
    eq(cursor(), { 3, 0 })
end)

t("n/N: nowrapscan stops at the edge", function()
    show({ "k1", "k2" }, { 1, 0 })
    type_keys("k[0-9]<CR>")
    ps.search()
    eq(cursor(), { 2, 0 })
    vim.o.wrapscan = false
    ps.next()
    eq(cursor(), { 2, 0 }) -- E385, no move
    vim.o.wrapscan = true
end)

t("n: re-runs the pattern after buffer edits", function()
    local b = show({ "start", "old_match9" }, { 1, 0 })
    type_keys("match[0-9]<CR>")
    ps.search()
    eq(cursor(), { 2, 4 })
    -- a new earlier match appears; native n would find it too
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "fresh match7" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    ps.next()
    eq(cursor(), { 1, 6 })
end)

t("search: takes @/ over and turns native highlighting off", function()
    show({ "zz qq" }, { 1, 0 })
    vim.fn.setreg("/", "zz") -- as if a native search were active
    vim.v.hlsearch = 1
    type_keys("qq<CR>")
    ps.search()
    eq(vim.fn.getreg("/"), "qq")
    eq(vim.v.hlsearch, 0) -- vim would highlight its own reading of the pattern
end)

t("n after * follows the native search, and our highlights go", function()
    local b = show({ "one two", "two one", "one two" }, { 1, 0 })
    type_keys("two<CR>")
    ps.search()
    eq(cursor(), { 1, 4 })
    assert(#search_marks(b) > 0, "expected pcre highlights")
    vim.api.nvim_win_set_cursor(0, { 2, 4 }) -- on the "one" of line 2
    vim.fn.feedkeys("*", "x") -- native search for \<one\>
    eq(cursor(), { 3, 0 })
    ps.next() -- native n: the next "one", not the pcre "two"
    eq(cursor(), { 1, 0 })
    eq(search_marks(b), {})
end)

-- star family ------------------------------------------------------------------

t("star: searches \\bword\\b and owns n/N", function()
    local b = show({ "one two", "two one", "onef one" }, { 1, 0 })
    search.search_cword()
    eq(vim.fn.getreg("/"), "\\bone\\b")
    eq(cursor(), { 2, 4 })
    eq(vim.v.hlsearch, 0) -- native highlighting stays off, ours is painted
    assert(#search_marks(b) > 0, "expected pcre highlights")
    search.next() -- pcre n: "onef" must not match
    eq(cursor(), { 3, 5 })
end)

t("star: backward (#) finds the previous occurrence", function()
    show({ "foo bar", "baz foo", "foo" }, { 2, 4 })
    search.search_cword({ backward = true })
    eq(cursor(), { 1, 0 })
end)

t("star: the g* flavour matches inside words", function()
    show({ "one onef", "bone" }, { 1, 0 })
    search.search_cword({ exact = false })
    eq(vim.fn.getreg("/"), "one")
    eq(cursor(), { 1, 4 })
    search.next()
    eq(cursor(), { 2, 1 })
end)

t("star: metacharacters in the word are escaped, matched literally", function()
    show({ "a.b axb", "a.b" }, { 1, 0 })
    vim.bo.iskeyword = vim.bo.iskeyword .. ",46" -- "." joins the word
    search.search_cword()
    eq(vim.fn.getreg("/"), "\\ba\\.b\\b")
    eq(cursor(), { 2, 0 }) -- "axb" does not match the literal dot
end)

t("star: no \\b against a non-word edge -- the word could never match itself", function()
    show({ "hi! say hi!" }, { 1, 0 })
    vim.bo.iskeyword = vim.bo.iskeyword .. ",33" -- "!" joins the word
    search.search_cword()
    eq(vim.fn.getreg("/"), "\\bhi!")
    eq(cursor(), { 1, 8 })
end)

t("star: unicode word chars bound with \\b (UCP)", function()
    show({ "кот и кот", "котик" }, { 1, 0 })
    search.search_cword()
    eq(vim.fn.getreg("/"), "\\bкот\\b")
    eq(cursor(), { 1, 10 })
    search.next() -- "котик" must not match: и is a word char to UCP \b
    eq(cursor(), { 1, 0 })
end)

t("star: blank line echoes E348 and moves nothing", function()
    show({ "", "word" }, { 1, 0 })
    search.search_cword()
    eq(cursor(), { 1, 0 })
end)

t("star: a count jumps count occurrences ahead", function()
    show({ "w w w w" }, { 1, 0 })
    vim.keymap.set("n", "*", search.search_cword)
    vim.fn.feedkeys("2*", "tx")
    eq(cursor(), { 1, 4 })
    vim.keymap.del("n", "*")
end)

t("n: a count jumps count matches", function()
    show({ "q1 q2 q3 q4" }, { 1, 0 })
    type_keys("q[0-9]<CR>")
    ps.search()
    eq(cursor(), { 1, 3 })
    vim.keymap.set("n", "n", ps.next)
    vim.fn.feedkeys("2n", "tx")
    eq(cursor(), { 1, 9 })
    vim.keymap.del("n", "n")
end)

-- native parity ----------------------------------------------------------------

t("direction: n after # continues backward, N forward, like native", function()
    show({ "word a", "word b", "word c" }, { 2, 0 })
    search.search_cword({ backward = true })
    eq(cursor(), { 1, 0 })
    eq(vim.v.searchforward, 0)
    search.next() -- backward: wraps to the last occurrence
    eq(cursor(), { 3, 0 })
    search.prev() -- N reverses: forward, wraps to the first
    eq(cursor(), { 1, 0 })
end)

t("echo: ? prefix after #, W [x/y] on a wrap", function()
    local chunks
    local real_echo = vim.api.nvim_echo
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_echo = function(c) chunks = c end
    show({ "word a", "word b" }, { 2, 0 })
    search.search_cword({ backward = true })
    assert(chunks[1][1]:sub(1, 1) == "?", chunks[1][1])
    assert(not chunks[2][1]:find("W [", 1, true), vim.inspect(chunks))
    search.next() -- backward from the first match: wraps
    assert(chunks[2][1]:find("W [", 1, true), vim.inspect(chunks))
    vim.api.nvim_echo = real_echo
end)

t("echo: shortmess S shows the wrap warning, sS suppresses it", function()
    local chunks
    local real_echo = vim.api.nvim_echo
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_echo = function(c) chunks = c end
    local sm = vim.o.shortmess
    vim.o.shortmess = sm .. "S"
    show({ "w1", "w2" }, { 2, 0 })
    type_keys("w[0-9]<CR>")
    ps.search() -- nothing strictly after (2,0): wraps to (1,0)
    eq(chunks[1][2], "WarningMsg")
    vim.o.shortmess = sm .. "sS"
    search.next()
    search.next() -- wraps again
    eq(chunks, { { "/w[0-9]" } })
    vim.o.shortmess = sm
    vim.api.nvim_echo = real_echo
end)

t("SearchWrapped fires on wrap, for / and for n", function()
    local fired = 0
    local au = vim.api.nvim_create_autocmd("SearchWrapped",
        { callback = function() fired = fired + 1 end })
    show({ "z1", "z2" }, { 2, 0 })
    type_keys("z[0-9]<CR>")
    ps.search() -- wraps to (1,0)
    eq(fired, 1)
    search.next() -- (2,0), no wrap
    eq(fired, 1)
    search.next() -- wraps
    eq(fired, 2)
    vim.api.nvim_del_autocmd(au)
end)

t("search: [count]/pat accepts the count'th match", function()
    show({ "c1 c2 c3" }, { 1, 0 })
    vim.keymap.set("n", "/", ps.search)
    vim.fn.feedkeys("2/c[0-9]" .. vim.keycode("<CR>"), "tx")
    eq(cursor(), { 1, 6 })
    vim.keymap.del("n", "/")
end)

t("search: <C-g> cycles the current match while typing", function()
    show({ "g1", "g2", "g3" }, { 1, 0 })
    type_keys("g[0-9]<C-g><CR>") -- current starts at (2,0), <C-g> -> (3,0)
    ps.search()
    eq(cursor(), { 3, 0 })
end)

t("search: <C-t> cycles back; ends clamp under 'nowrapscan'", function()
    show({ "t1", "t2" }, { 1, 0 })
    type_keys("t[0-9]<C-t><CR>") -- (2,0) back to (1,0)
    ps.search()
    eq(cursor(), { 1, 0 })
    vim.o.wrapscan = false
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    type_keys("t[0-9]<C-t><C-t><CR>") -- second <C-t> would wrap: stays
    ps.search()
    eq(cursor(), { 1, 0 })
    vim.o.wrapscan = true
end)

t("search: typing paints the current match IncSearch, the rest Search", function()
    local b = show({ "inc1 x", "inc2" }, { 1, 5 })
    local snap
    vim.keymap.set("c", "<F8>", function() snap = search_marks(b) end)
    type_keys("inc[0-9]<F8><CR>")
    ps.search()
    vim.keymap.del("c", "<F8>")
    eq(snap, {
        { 0, 0, 4, "Search" },
        { 1, 0, 4, "IncSearch" },
    })
end)

t("search: with 'nohlsearch' only the current match paints while typing", function()
    vim.o.hlsearch = false
    local b = show({ "nh1 x", "nh2" }, { 1, 5 })
    local snap
    vim.keymap.set("c", "<F8>", function() snap = search_marks(b) end)
    type_keys("nh[0-9]<F8><Esc>")
    ps.search()
    vim.keymap.del("c", "<F8>")
    eq(snap, { { 1, 0, 3, "IncSearch" } })
    vim.o.hlsearch = true
end)

t("search: <C-r><C-l> inserts the line under the cursor", function()
    show({ "lineful" }, { 1, 0 })
    type_keys("<C-r><C-l><CR>")
    ps.search()
    eq(vim.fn.getreg("/"), "lineful")
end)

t(":S owns n/N and relights highlights, like native :s", function()
    ps.setup({}) -- :S registration; idempotent for these tests
    local b = show({ "foo bar", "foo foo" }, { 1, 0 })
    vim.fn.feedkeys(":%S/foo/X/\r", "tx") -- first per line without /g
    eq(lines_of(b), { "X bar", "X foo" })
    eq(vim.fn.getreg("/"), "foo")
    search.next() -- pcre n: the surviving foo
    eq(cursor(), { 2, 2 })
    assert(#search_marks(b) > 0, "expected pcre highlights after :S")
end)

t(":S with no match still owns the pattern, like native :s", function()
    show({ "aaa" }, { 1, 0 })
    -- the not-found notify is an error message, which raises under -l
    pcall(vim.fn.feedkeys, ":S/zzz/x/\r", "tx")
    eq(vim.fn.getreg("/"), "zzz")
end)

t(":S// reuses the last pcre pattern", function()
    local b = show({ "roo koo" }, { 1, 0 })
    type_keys("[rk]oo<CR>")
    ps.search()
    vim.fn.feedkeys(":S//X/g\r", "tx")
    eq(lines_of(b), { "X X" })
end)

t("run: 'gdefault' inverts /g, like native", function()
    vim.o.gdefault = true
    local b = show({ "oo oo" }, { 1, 0 })
    vim.fn.feedkeys(":S/oo/X/\r", "tx")
    eq(lines_of(b), { "X X" }) -- g is the default now
    local b2 = show({ "ee ee" }, { 1, 0 })
    vim.fn.feedkeys(":S/ee/Y/g\r", "tx")
    eq(lines_of(b2), { "Y ee" }) -- and /g turns it back off
    vim.o.gdefault = false
end)

t("search: hlsearch off leaves no highlights after accept", function()
    vim.o.hlsearch = false
    local b = show({ "hlfoo" }, { 1, 4 })
    type_keys("hlfoo<CR>")
    ps.search()
    eq(cursor(), { 1, 0 }) -- wrapped
    eq(search_marks(b), {})
    vim.o.hlsearch = true
end)

t(":noh clears search highlights (CmdlineLeave hook)", function()
    ps.setup({}) -- hook registration; idempotent for this test
    local b = show({ "nohfoo nohfoo" }, { 1, 3 })
    type_keys("nohfoo<CR>")
    ps.search()
    assert(#search_marks(b) == 2, "expected highlights before :noh")
    vim.fn.feedkeys(":noh\r", "x")
    eq(search_marks(b), {})
end)

-- substitute: parse and replacement template ---------------------------------

t("parse: pattern, replacement, flags", function()
    eq(sub.parse("/a b/c/gi"), { pat = "a b", repl = "c", flags = { g = true, i = true } })
end)

t("parse: alternative separator and escaped separator", function()
    eq(sub.parse("#a/b#c#"), { pat = "a/b", repl = "c", flags = {} })
    eq(sub.parse([[/a\/b/c/]]), { pat = "a/b", repl = "c", flags = {} })
end)

t("parse: missing replacement deletes", function()
    eq(sub.parse("/foo"), { pat = "foo", repl = "", flags = {} })
end)

t("parse: rejects unknown flags and stray separator in flags", function()
    local _, err = sub.parse("/a/b/z")
    assert(err and err:find("unsupported"), err)
    local _, err3 = sub.parse("/a/b/g/x")
    assert(err3 and err3:find("unsupported"), err3)
end)

t("parse: empty pattern is legal -- :S// reuses the last search", function()
    eq(sub.parse("//b/"), { pat = "", repl = "b", flags = {} })
end)

t("normalize_repl: adjacency, vim backrefs, literals", function()
    eq(sub.normalize_repl("$1X"), "${1}X")
    eq(sub.normalize_repl([[\1X]]), "${1}X")
    eq(sub.normalize_repl("${name}"), "${name}")
    eq(sub.normalize_repl("$$1"), "$$1")
    eq(sub.normalize_repl([[a\\1]]), [[a\1]])
end)

-- substitute: end to end ------------------------------------------------------

t("run: /g with capture groups", function()
    local b = show({ "foo1 foo2", "foo3" })
    sub.run({ args = [[/foo(\d)/n$1/g]], line1 = 1, line2 = 2 })
    eq(lines_of(b), { "n1 n2", "n3" })
end)

t("run: without /g only first match per line", function()
    local b = show({ "foo foo foo" })
    sub.run({ args = "/foo/bar/", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "bar foo foo" })
end)

t("run: range limits the edits", function()
    local b = show({ "foo", "foo", "foo" })
    sub.run({ args = "/foo/bar/", line1 = 2, line2 = 2 })
    eq(lines_of(b), { "foo", "bar", "foo" })
end)

t("run: i flag", function()
    local b = show({ "FOO foo" })
    sub.run({ args = "/foo/x/gi", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "x x" })
end)

t("run: lookbehind", function()
    local b = show({ "ab xb" })
    sub.run({ args = [[/(?<=a)b/B/g]], line1 = 1, line2 = 1 })
    eq(lines_of(b), { "aB xb" })
end)

t("run: backreference in the pattern", function()
    local b = show({ "hey hey yo yo end" })
    sub.run({ args = [[/(\w+) \1/dup/g]], line1 = 1, line2 = 1 })
    eq(lines_of(b), { "dup dup end" })
end)

t("run: named groups, $0, literal $$", function()
    local b = show({ "num 42 here" })
    sub.run({ args = [[/(?<n>\d+)/<${n}>/g]], line1 = 1, line2 = 1 })
    eq(lines_of(b), { "num <42> here" })
    local b2 = show({ "foo" })
    sub.run({ args = "/foo/[$0]$$/", line1 = 1, line2 = 1 })
    eq(lines_of(b2), { "[foo]$" })
end)

t("run: empty replacement deletes matches", function()
    local b = show({ "fo0o barr0" })
    sub.run({ args = "/[0r]//g", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "foo ba" })
end)

t("run: different-length replacements on one line keep offsets straight", function()
    local b = show({ "aaa b aa c a" })
    sub.run({ args = "/a+/[$0]/g", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "[aaa] b [aa] c [a]" })
end)

t("run: multibyte line, byte-accurate edit", function()
    local b = show({ "π = wörld" })
    sub.run({ args = "/wörld/world/", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "π = world" })
end)

t("run: zero-width pattern inserts at each position", function()
    local b = show({ "foo" })
    sub.run({ args = [[/(?=o)/-/g]], line1 = 1, line2 = 1 })
    eq(lines_of(b), { "f-o-o" })
end)

t("run: no match notifies and leaves the buffer alone", function()
    local b = show({ "abc" })
    local msg
    local orig = vim.notify
    vim.notify = function(m, _)
        msg = m
    end
    sub.run({ args = "/zzz/x/", line1 = 1, line2 = 1 })
    vim.notify = orig
    assert(msg and msg:find("Pattern not found"), tostring(msg))
    eq(lines_of(b), { "abc" })
end)

t("run: bad pattern surfaces the PCRE2 error via notify", function()
    local b = show({ "abc" })
    local msg
    local orig = vim.notify
    vim.notify = function(m, _)
        msg = m
    end
    sub.run({ args = "/(?=/x/", line1 = 1, line2 = 1 })
    vim.notify = orig
    assert(msg and msg:find("PCRE2"), tostring(msg))
    eq(lines_of(b), { "abc" })
end)

-- substitute: confirm flag ----------------------------------------------------

t("run: /c with y/n/y keeps first and third", function()
    local b = show({ "foo foo foo" })
    type_keys("yny")
    sub.run({ args = "/foo/bar/gc", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "bar foo bar" })
end)

t("run: /c with a accepts everything from there on", function()
    local b = show({ "foo foo foo" })
    type_keys("na")
    sub.run({ args = "/foo/bar/gc", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "foo bar bar" })
end)

t("run: /c with l replaces the current one and stops", function()
    local b = show({ "foo foo foo" })
    type_keys("l")
    sub.run({ args = "/foo/bar/gc", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "bar foo foo" })
end)

t("run: /c with q (and with <Esc>) changes nothing", function()
    local b = show({ "foo foo" })
    type_keys("q")
    sub.run({ args = "/foo/bar/gc", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "foo foo" })
    type_keys("<Esc>")
    sub.run({ args = "/foo/bar/gc", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "foo foo" })
end)

t("run: /c ignores unknown keys and asks again", function()
    local b = show({ "foo foo" })
    type_keys("zyn") -- z is not an answer; same match asked again
    sub.run({ args = "/foo/bar/gc", line1 = 1, line2 = 1 })
    eq(lines_of(b), { "bar foo" })
end)

-- substitute: preview ---------------------------------------------------------

t("preview: modifies buffer and reports a preview", function()
    local b = show({ "foo1" })
    local ret = sub.preview({ args = [[/foo(\d)/n$1/g]], line1 = 1, line2 = 1 },
        vim.api.nvim_create_namespace("t"), nil)
    eq(ret, 1)
    eq(lines_of(b), { "n1" })
end)

t("preview: highlight spans account for same-line length drift", function()
    local b = show({ "aaa b aa" })
    local pns = vim.api.nvim_create_namespace("t2")
    sub.preview({ args = "/a+/[$0]/g", line1 = 1, line2 = 1 }, pns, nil)
    eq(lines_of(b), { "[aaa] b [aa]" })
    local marks = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, pns, 0, -1, { details = true })) do
        marks[#marks + 1] = { m[2], m[3], m[4].end_col }
    end
    eq(marks, { { 0, 0, 5 }, { 0, 8, 12 } })
end)

t("preview: fills the preview buffer and returns 2", function()
    local b = show({ "xx", "foo7", "yy", "foo8" })
    local pbuf = vim.api.nvim_create_buf(false, true)
    local ret = sub.preview({ args = [[/foo(\d)/n$1/]], line1 = 1, line2 = 4 },
        vim.api.nvim_create_namespace("t3"), pbuf)
    eq(ret, 2)
    eq(lines_of(b), { "xx", "n7", "yy", "n8" })
    eq(lines_of(pbuf), { "|2| n7", "|4| n8" })
end)

t("preview: unparsable input previews nothing", function()
    eq(sub.preview({ args = "x", line1 = 1, line2 = 1 }, 1, nil), 0)
end)

-- setup, command, abbreviation ------------------------------------------------

t("setup: registers :S", function()
    ps.setup({ substitute_abbrev = true })
    assert(vim.fn.exists(":S") == 2, ":S not registered")
end)

t(":S via nvim_cmd with a range", function()
    local b = show({ "foo", "foo" })
    vim.api.nvim_cmd({ cmd = "S", args = { "/foo/bar/" }, range = { 1, 2 } }, {})
    eq(lines_of(b), { "bar", "bar" })
end)

-- fo(?=o) is valid PCRE2 but an error in vim regex, so a change proves the
-- rewritten :S ran, not native :s
t("s-rewrite: typed :%s/ runs :S (pcre2 pattern proves it)", function()
    local b = show({ "foo foo" })
    vim.fn.feedkeys(":%s/fo(?=o)/x/g\r", "tx")
    eq(lines_of(b), { "xo xo" })
end)

t("s-rewrite: bare :s/ and a numeric range", function()
    local b = show({ "foo" })
    vim.fn.feedkeys(":s/fo(?=o)/x/\r", "tx")
    eq(lines_of(b), { "xo" })
    local b2 = show({ "foo", "foo", "foo" })
    vim.fn.feedkeys(":2,3s/fo(?=o)/x/\r", "tx")
    eq(lines_of(b2), { "foo", "xo", "xo" })
end)

t("s-rewrite: visual '<,'> range", function()
    local b = show({ "foo", "foo" })
    vim.fn.feedkeys("VG\27", "tx") -- set the marks
    vim.fn.feedkeys(":'<,'>s/fo(?=o)/x/\r", "tx")
    eq(lines_of(b), { "xo", "xo" })
end)

t("s-rewrite: does not fire mid-word or after :g//", function()
    local b = show({ "sort me" })
    vim.fn.feedkeys(":sort\r", "tx") -- :sort must stay :sort
    eq(lines_of(b), { "sort me" })
    -- inside a pattern position, "s" stays "s": :g/s/d deletes the line
    local b2 = show({ "has s", "none" })
    vim.fn.feedkeys(":g/s/d\r", "tx")
    eq(lines_of(b2), { "none" })
end)

t("s-rewrite: :su stays native (the escape hatch)", function()
    local b = show({ "n.n" })
    -- vim-regex \. -- under :S the pcre2 pattern n\.n would also match, but
    -- native :su proves itself by accepting a vim-only atom \zs
    vim.fn.feedkeys(":su/n\\zs.\\zen/-/\r", "tx")
    eq(lines_of(b), { "n-n" })
end)

-- toggle -----------------------------------------------------------------------
-- Vim-only atoms (\zs, \ze) are the proof that the native command ran: they are
-- errors to PCRE2. Last section on purpose -- the flag is process-global.

t("toggle: off hands / back to native", function()
    local b = show({ "n.n" })
    -- typed, not ps.toggle(): proves :Pcre reaches it and that the :s rewrite
    -- keeps its hands off a command starting with anything but a range
    vim.fn.feedkeys(":Pcre\r", "tx")
    assert(not ps.enabled(), "still enabled after :Pcre")
    ps.search()
    type_keys([[n\zs.\zen<CR>]])
    vim.api.nvim_feedkeys("", "x", false) -- flush the typeahead
    eq(cursor(), { 1, 1 })
    eq(lines_of(b), { "n.n" })
end)

t("toggle: off leaves a typed :s native, :S still pcre", function()
    local b = show({ "n.n" })
    vim.fn.feedkeys([[:s/n\zs.\zen/-/]] .. "\r", "tx")
    eq(lines_of(b), { "n-n" })
    local b2 = show({ "foo" })
    vim.fn.feedkeys(":S/fo(?=o)/x/\r", "tx")
    eq(lines_of(b2), { "xo" })
end)

t("toggle: back on restores / and the :s rewrite", function()
    vim.fn.feedkeys(":Pcre\r", "tx")
    assert(ps.enabled(), "still disabled after the second :Pcre")
    local b = show({ "foo foo" })
    type_keys("fo(?=o)<CR>")
    ps.search()
    eq(cursor(), { 1, 4 })
    vim.fn.feedkeys(":s/fo(?=o)/x/g\r", "tx")
    eq(lines_of(b), { "xo xo" })
end)

if failed > 0 then
    print(("%d test(s) FAILED"):format(failed))
    vim.cmd("cq")
end
print("all tests passed")
