-- Second offline tier: the edges spec.lua does not reach -- history navigation
-- in the prompt, ownership of n/N after a failed search, the jump mark, the
-- one-pass match+expand agreement, the 'report' message, preview without a preview
-- window, and the exact firing conditions of the :noh and :s hooks.
--
-- Its own nvim (run.sh loops over tests/spec*.lua): the module's last-pattern
-- state is process-global and several tests here need it fresh.
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

local function show(lines, cursor)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
    return b
end

local function lines_of(b)
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function cursor()
    return vim.api.nvim_win_get_cursor(0)
end

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

-- record what the module echoes: nvim_echo with history=false never reaches
-- :messages, so intercepting the call is the only way to assert on it
local function capture_echo(fn)
    local real = vim.api.nvim_echo
    local seen = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_echo = function(chunks, history, opts)
        local text = ""
        for _, c in ipairs(chunks) do
            text = text .. c[1]
        end
        seen[#seen + 1] = text
        return real(chunks, history, opts)
    end
    local ok, err = pcall(fn)
    vim.api.nvim_echo = real
    if not ok then
        error(err, 0)
    end
    return seen
end

local sub = require("pcre.substitute")
local ps = require("pcre")

-- :S must be a user command before the substitute tests: without setup() the
-- name still resolves (exists(":S") == 1, an abbreviation of a builtin) and
-- nvim_cmd runs it silently, so the tests would pass through doing nothing.
ps.setup({})

-- prompt loop: history and ownership -----------------------------------------

t("search: a failed search still owns n/N", function()
    local b = show({ "nothing here" }, { 1, 0 })
    type_keys("zebra<CR>")
    ps.search()
    eq(cursor(), { 1, 0 })
    eq(vim.fn.getreg("/"), "zebra") -- E486, but the pattern is ours now
    -- n re-runs it live, so it finds the text once it exists
    vim.api.nvim_buf_set_lines(b, 1, 1, false, { "a zebra appears" })
    ps.next()
    eq(cursor(), { 2, 2 })
end)

t("search: <Down> comes back to the pattern <Up> stashed", function()
    vim.fn.histadd("search", "alpha")
    show({ "x beta" }, { 1, 0 })
    type_keys("bet<Up><Down>a<CR>") -- "bet" -> "alpha" -> "bet" -> "beta"
    ps.search()
    eq(cursor(), { 1, 2 })
end)

t("search: <C-p>/<C-n> are <Up>/<Down>", function()
    vim.fn.histadd("search", "gamma")
    show({ "q delta" }, { 1, 0 })
    type_keys("del<C-p><C-n>ta<CR>")
    ps.search()
    eq(cursor(), { 1, 2 })
end)

t("search: <Up> past the oldest entry stays on it", function()
    vim.fn.histdel("search")
    vim.fn.histadd("search", "only")
    show({ "an only child" }, { 1, 0 })
    type_keys("<Up><Up><Up><CR>")
    ps.search()
    eq(cursor(), { 1, 3 })
end)

t("search: an accepted pattern lands in the search history", function()
    vim.fn.histdel("search")
    show({ "hist target" }, { 1, 0 })
    type_keys("targ.t<CR>")
    ps.search()
    eq(vim.fn.histget("search", -1), "targ.t")
end)

t("search: <C-r> of an empty register inserts nothing", function()
    vim.fn.setreg("z", "")
    show({ "z regfoo" }, { 1, 0 })
    type_keys("<C-r>zregfoo<CR>")
    ps.search()
    eq(cursor(), { 1, 2 })
end)

t("search: an unfinished pattern is not an error, just no matches", function()
    local b = show({ "aa foo bb" }, { 1, 0 })
    -- "fo(" is a PCRE2 syntax error mid-typing; completing it must recover
    type_keys("fo(<BS>(o)<CR>")
    ps.search()
    eq(cursor(), { 1, 3 })
    eq(search_marks(b), { { 0, 3, 6, "CurSearch" } })
end)

t("search: accepting sets the ' mark, so `` returns to the origin", function()
    show({ "start", "x", "x", "needle here" }, { 1, 0 })
    type_keys("needle<CR>")
    ps.search()
    eq(cursor(), { 4, 0 })
    vim.fn.feedkeys("``", "x")
    eq(cursor(), { 1, 0 })
end)

t("search: cancelling restores the scroll position, not just the cursor", function()
    local lines = {}
    for i = 1, 300 do
        lines[i] = "line " .. i
    end
    lines[290] = "scrollneedle"
    show(lines, { 1, 0 })
    vim.api.nvim_win_set_cursor(0, { 150, 0 })
    vim.cmd("normal! zz")
    local before = vim.fn.winsaveview()
    type_keys("scrollneedle<Esc>")
    ps.search()
    local after = vim.fn.winsaveview()
    eq({ after.lnum, after.col, after.topline }, { before.lnum, before.col, before.topline })
end)

t("n: a zero-width match does not trap the cursor", function()
    show({ "abcabc" }, { 1, 0 })
    type_keys("(?=b)<CR>")
    ps.search()
    eq(cursor(), { 1, 1 })
    ps.next()
    eq(cursor(), { 1, 4 })
    ps.next() -- wraps back to the first
    eq(cursor(), { 1, 1 })
end)

t("clear: drops highlights in every loaded buffer, not just the current one", function()
    local a = show({ "clearme here" }, { 1, 5 })
    type_keys("clearme<CR>")
    ps.search()
    assert(#search_marks(a) > 0, "expected highlights in buffer a")
    local b = show({ "clearme there" }, { 1, 5 })
    type_keys("clearme<CR>")
    ps.search()
    assert(#search_marks(b) > 0, "expected highlights in buffer b")
    ps.clear()
    eq(search_marks(a), {})
    eq(search_marks(b), {})
end)

-- substitute -----------------------------------------------------------------

t("compute: a replacement that spans lines is refused, not misapplied", function()
    local b = show({ "aXb" })
    local spec = assert(sub.parse("/X/p/"))
    spec.repl = "p\nq" -- rg -r prints two lines: the match/expansion zip breaks
    local edits, err = sub.compute(b, 1, 1, spec)
    eq(edits, nil)
    assert(err and err:find("multiple lines", 1, true), "unexpected error: " .. tostring(err))
    eq(lines_of(b), { "aXb" })
end)

t("compute: the two rg passes agree about /i", function()
    -- if -i reached only the --json pass, the zip would pair match 2 with a
    -- replacement that was never produced
    local b = show({ "Foo foo FOO" })
    local spec = assert(sub.parse("/foo/<&>/gi"))
    spec.repl = "[$0]"
    local edits = assert(sub.compute(b, 1, 1, spec))
    eq(#edits, 3)
    eq(vim.tbl_map(function(e)
        return e.text
    end, edits), { "[Foo]", "[foo]", "[FOO]" })
end)

t("compute: lines without matches do not shift the zip", function()
    local b = show({ "a1 a2", "bb", "a3" })
    local spec = assert(sub.parse([[/a(\d)/<$1>/g]]))
    local edits = assert(sub.compute(b, 1, 3, spec))
    eq(vim.tbl_map(function(e)
        return { e.lnum, e.text }
    end, edits), { { 1, "<1>" }, { 1, "<2>" }, { 3, "<3>" } })
end)

t("run: the cursor ends on the first non-blank of the last substituted line", function()
    local b = show({ "oo", "x", "  oo" }, { 1, 0 })
    vim.api.nvim_cmd({ cmd = "S", args = { "/o/0/g" }, range = { 1, 3 } }, {})
    eq(lines_of(b), { "00", "x", "  00" })
    eq(cursor(), { 3, 2 }) -- first non-blank, like native :s (measured)
end)

t("run: reports the count only above 'report'", function()
    local report = vim.o.report
    vim.o.report = 0
    show({ "aa", "aa" })
    local msgs = capture_echo(function()
        vim.api.nvim_cmd({ cmd = "S", args = { "/a/b/g" }, range = { 1, 2 } }, {})
    end)
    eq(msgs, { "4 substitutions on 2 lines" })

    show({ "aa" })
    msgs = capture_echo(function()
        vim.api.nvim_cmd({ cmd = "S", args = { "/aa/b/" }, range = { 1, 1 } }, {})
    end)
    eq(msgs, { "1 substitution on 1 line" })

    vim.o.report = 5
    show({ "aa", "aa" })
    msgs = capture_echo(function()
        vim.api.nvim_cmd({ cmd = "S", args = { "/a/b/g" }, range = { 1, 2 } }, {})
    end)
    eq(msgs, {})
    vim.o.report = report
end)

t("preview: returns 1 and highlights in place when there is no preview window", function()
    local b = show({ "prev foo" })
    local ns = vim.api.nvim_create_namespace("pcre.test.preview")
    local rc = sub.preview({ args = "/foo/BARBAR/", line1 = 1, line2 = 1 }, ns, nil)
    eq(rc, 1)
    eq(lines_of(b), { "prev BARBAR" })
    local marks = vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })
    eq(#marks, 1)
    eq({ marks[1][2], marks[1][3], marks[1][4].end_col, marks[1][4].hl_group },
        { 0, 5, 11, "Substitute" })
end)

t("preview: an rg error previews nothing and leaves the buffer alone", function()
    local b = show({ "bad pattern here" })
    local ns = vim.api.nvim_create_namespace("pcre.test.preview2")
    eq(sub.preview({ args = "/pat(tern/x/", line1 = 1, line2 = 1 }, ns, nil), 0)
    eq(lines_of(b), { "bad pattern here" })
end)

t("preview: no match previews nothing", function()
    local b = show({ "abc" })
    local ns = vim.api.nvim_create_namespace("pcre.test.preview3")
    eq(sub.preview({ args = "/zzz/x/", line1 = 1, line2 = 1 }, ns, nil), 0)
    eq(lines_of(b), { "abc" })
end)

t("parse: all three flags, and a regex-metachar separator", function()
    eq(sub.parse("/a/b/gci"), { pat = "a", repl = "b", flags = { g = true, c = true, i = true } })
    eq(sub.parse(".a.b.g"), { pat = "a", repl = "b", flags = { g = true } })
    eq(sub.parse("#a#b#"), { pat = "a", repl = "b", flags = {} })
end)

t("parse: an escaped separator inside the replacement", function()
    eq(sub.parse("/a/x\\/y/"), { pat = "a", repl = "x/y", flags = {} })
end)

t("parse: text after the third separator is flags, not replacement", function()
    -- a fourth separator is literal: parts stops splitting at three
    eq(sub.parse("/a/b/g"), { pat = "a", repl = "b", flags = { g = true } })
    local spec, err = sub.parse("/a/b/g/x")
    eq(spec, nil)
    assert(err and err:find("unsupported flag: /"), "unexpected: " .. tostring(err))
end)

t("parse: a separator vim would not accept either", function()
    for _, args in ipairs({ "", "sa/b/", [[\a\b\]], "\"a\"b\"", "|a|b|" }) do
        local spec = sub.parse(args)
        eq(spec, nil)
    end
end)

t("normalize_repl: multi-digit groups, \\0, and escapes", function()
    eq(sub.normalize_repl("$10"), "${10}")
    eq(sub.normalize_repl("$1 0"), "${1} 0")
    eq(sub.normalize_repl("\\0-\\9"), "${0}-${9}")
    eq(sub.normalize_repl("$$1"), "$$1")
    eq(sub.normalize_repl("a\\\\b"), "a\\b")
    eq(sub.normalize_repl("trail\\"), "trail\\")
    eq(sub.normalize_repl("${2}"), "${2}") -- already canonical, left alone
end)

t("run: a multi-digit group actually expands", function()
    local b = show({ "abcdefghijk" })
    vim.api.nvim_cmd({ cmd = "S",
        args = { [[/(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)/$11$1/]] }, range = { 1, 1 } }, {})
    eq(lines_of(b), { "ka" })
end)

-- hooks ----------------------------------------------------------------------

t(":noh fires for every unambiguous abbreviation, and only those", function()
    local function marks_after(cmdline)
        local b = show({ "hookme hookme" }, { 1, 3 })
        type_keys("hookme<CR>")
        ps.search()
        assert(#search_marks(b) == 2, "expected highlights before " .. cmdline)
        -- pcall: the non-matching lines are E492, and the hook must have run
        -- (or not) regardless of whether the command itself existed
        pcall(vim.fn.feedkeys, cmdline, "tx")
        return #search_marks(b)
    end
    eq(marks_after(":noh\r"), 0)
    eq(marks_after(":nohl\r"), 0)
    eq(marks_after(":nohlsearch\r"), 0)
    eq(marks_after(":noh  \r"), 0) -- trailing whitespace is still :noh
    eq(marks_after(":nohx\r"), 2) -- not a prefix of nohlsearch
    eq(marks_after(":nohlsearchx\r"), 2) -- longer than the command
    -- the >= 3 guard is not exercised here on purpose: the only two-letter
    -- prefix is ":no", which really is ":noremap" and dumps every mapping
    eq(marks_after(":noh\27"), 2) -- aborted cmdline changes nothing
end)

t("s-rewrite: fires for every range form", function()
    ps.setup({ substitute_abbrev = true })
    local b = show({ "foo", "foo", "foo", "foo" })
    vim.fn.feedkeys(":.,+1s/fo(?=o)/x/\r", "tx")
    eq(lines_of(b), { "xo", "xo", "foo", "foo" })
    vim.fn.feedkeys(":$s/fo(?=o)/y/\r", "tx")
    eq(lines_of(b), { "xo", "xo", "foo", "yo" })
    vim.fn.feedkeys(":3s/fo(?=o)/z/\r", "tx")
    eq(lines_of(b), { "xo", "xo", "zo", "yo" })
end)

t("s-rewrite: fires for any legal separator", function()
    local b = show({ "foo foo" })
    vim.fn.feedkeys(":%s#fo(?=o)#x#g\r", "tx")
    eq(lines_of(b), { "xo xo" })
    vim.fn.feedkeys(":%s,x,q,g\r", "tx")
    eq(lines_of(b), { "qo qo" })
end)

t("s-rewrite: leaves the cmdline alone for separators :S cannot take", function()
    local seen = {}
    -- registered after pcre's, so this sees the line as pcre left it
    local group = vim.api.nvim_create_augroup("pcre.test.abbrev", {})
    vim.api.nvim_create_autocmd("CmdlineChanged", {
        group = group,
        callback = function()
            seen[#seen + 1] = vim.fn.getcmdline()
        end,
    })
    local function typed(keys)
        seen = {}
        vim.fn.feedkeys(keys .. "\27", "tx")
        return seen[#seen]
    end
    eq(typed(":s/"), "S/") -- the control: this one does fire
    eq(typed(":s|"), "s|")
    eq(typed(":s\""), "s\"")
    eq(typed(":s\\"), "s\\")
    eq(typed(":sx"), "sx")
    eq(typed(":s "), "s ")
    eq(typed(":ss"), "ss")
    vim.api.nvim_del_augroup_by_id(group)
end)

if failed > 0 then
    print(("%d test(s) FAILED"):format(failed))
    vim.cmd("cq")
end
print("all tests passed")
