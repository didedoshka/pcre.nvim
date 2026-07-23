-- Parity tier: the plugin against nvim's own engine, on patterns that mean the
-- same thing in both syntaxes (literals, [0-9]+, ^/$ anchors). Everything here
-- would also pass with "/" and ":s" -- that is the point.
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

local function type_keys(keys)
    -- "t": handled as typed -- a mapped <Esc> in the cmdline would act like <CR>
    -- (:h c_<Esc>), and the prompt's own temporary c-mode maps must fire
    vim.fn.feedkeys(vim.keycode(keys), "t")
end

local search = require("pcre.search")
local ps = require("pcre")
ps.setup({})

local corpus = {
    "foo bar foo",
    "",
    "line 42 and 7",
    "xfoo",
    "  indented foo  ",
    "π multibyte wörld 9",
    "foo",
}

-- both-syntax patterns: identical meaning in PCRE2 and vim regex ('magic')
local common = { "foo", "[0-9][0-9]*", "^x", "o $", "^$", "w.rld" }

t("find agrees with matchbufline for every common pattern", function()
    local b = show(corpus)
    for _, pat in ipairs(common) do
        local ours = {}
        for _, m in ipairs(assert(search.find(b, pat))) do
            ours[#ours + 1] = { m.lnum, m.scol, m.ecol }
        end
        local native = {}
        for _, m in ipairs(vim.fn.matchbufline(b, pat, 1, "$")) do
            native[#native + 1] = { m.lnum, m.byteidx, m.byteidx + #m.text }
        end
        assert(vim.deep_equal(ours, native),
            ("pattern %q: ours %s, native %s"):format(pat,
                vim.inspect(ours), vim.inspect(native)))
    end
end)

t("accepted count equals searchcount()", function()
    show(corpus, { 1, 0 })
    type_keys("foo<CR>")
    ps.search()
    -- @/ now holds the pattern (own()), so native searchcount sees the same one:
    -- 5 foos, and the accept landed the cursor on the second
    local sc = vim.fn.searchcount({ recompute = 1, maxcount = 0 })
    eq({ sc.current, sc.total }, { 2, 5 })
end)

t("n trajectory matches native search() over a full wrap", function()
    show(corpus, { 1, 0 })
    type_keys("foo<CR>")
    ps.search()
    local ours = { cursor() }
    for _ = 1, 4 do
        ps.next()
        ours[#ours + 1] = cursor()
    end
    -- native trajectory from the same origin, same pattern, wrapscan on
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local native = {}
    for _ = 1, 5 do
        vim.fn.search("foo", "w")
        local p = cursor()
        native[#native + 1] = { p[1], p[2] }
    end
    eq(ours, native)
end)

t("N trajectory matches native backward search", function()
    show(corpus, { 3, 0 })
    type_keys("foo<CR>")
    ps.search()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local ours = {}
    for _ = 1, 4 do
        ps.prev()
        ours[#ours + 1] = cursor()
    end
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local native = {}
    for _ = 1, 4 do
        vim.fn.search("foo", "bw")
        local p = cursor()
        native[#native + 1] = { p[1], p[2] }
    end
    eq(ours, native)
end)

t(":S output equals :s for /g, first-per-line, range and /i", function()
    local cases = {
        { spec = "/foo/X/g", range = { 1, 7 } },
        { spec = "/foo/X/", range = { 1, 7 } },
        { spec = "/[0-9][0-9]*/N/g", range = { 1, 7 } },
        { spec = "/FOO/X/gi", range = { 1, 7 } },
        { spec = "/foo/X/g", range = { 3, 5 } },
    }
    for _, c in ipairs(cases) do
        local a = show(corpus)
        vim.api.nvim_cmd({ cmd = "S", args = { c.spec }, range = c.range }, {})
        local got = lines_of(a)
        local b = show(corpus)
        vim.api.nvim_cmd({ cmd = "substitute", args = { c.spec .. "e" },
            range = c.range, magic = { file = false } }, {})
        eq(got, lines_of(b))
    end
end)

-- ideas.md fixes --------------------------------------------------------------

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

t("accepting echoes /pattern with a right-aligned [cur/total]", function()
    show(corpus, { 1, 0 })
    local seen = capture_echo(function()
        type_keys("foo<CR>")
        ps.search()
    end)
    local last = seen[#seen]
    local pat, count = last:match("^(/foo)%s+(%[2/5%])$")
    assert(pat and count, "unexpected echo: " .. vim.inspect(last))
    -- while typing the echo is the bare pattern: native shows the count only
    -- once the search is accepted
    for i = 1, #seen - 1 do
        assert(not seen[i]:find("[", 1, true), "count echoed while typing: " .. seen[i])
    end
    -- right-aligned, but clear of the 'showcmd' cells: a message reaching into
    -- them triggers a hit-enter prompt (measured on 0.13-dev)
    eq(#last, vim.o.columns - (vim.o.showcmd and 12 or 1))
end)

t("with 'noincsearch' nothing moves or counts until <CR>", function()
    show(corpus, { 1, 0 })
    vim.o.incsearch = false
    local moved = {} -- cursor positions set while the prompt is open
    local real_set = vim.api.nvim_win_set_cursor
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_win_set_cursor = function(w, pos)
        moved[#moved + 1] = pos
        return real_set(w, pos)
    end
    local ok, err = pcall(function()
        local seen = capture_echo(function()
            type_keys("foo<CR>")
            ps.search()
        end)
        -- while typing nothing is echoed at all (the cmdline draws itself,
        -- there is no jump); <CR> jumps and counts
        assert(seen[#seen]:match("^/foo%s+%[2/5%]$"), "unexpected accept echo: " .. seen[#seen])
        for i = 1, #seen - 1 do
            assert(not seen[i]:find("/foo", 1, true), "echoed while typing: " .. seen[i])
        end
        eq(moved, { { 1, 8 } })
    end)
    vim.api.nvim_win_set_cursor = real_set
    vim.o.incsearch = true
    if not ok then
        error(err, 0)
    end
end)

t("a terminal paste lands in the pattern, newlines flattened", function()
    show({ "x", "paste me" }, { 1, 0 })
    -- a bracketed paste while prompting goes through vim.paste, never through
    -- getcharstr; schedule it so it fires while the loop waits for input
    vim.schedule(function()
        vim.paste({ "paste", "me" }, -1)
    end)
    vim.schedule(function()
        type_keys("<CR>")
    end)
    local saved = vim.paste
    ps.search()
    eq(cursor(), { 2, 0 })
    assert(vim.paste == saved, "vim.paste was not restored")
end)

t("zero-width matches paint one visible cell", function()
    show({ "foo" }, { 1, 0 })
    type_keys("(?=o)<CR>")
    ps.search()
    local widths = {}
    for _, m in ipairs(vim.fn.getmatches(0)) do
        for i = 1, 8 do
            local p = m["pos" .. i]
            if type(p) == "table" then
                widths[#widths + 1] = p[3]
            end
        end
    end
    eq(widths, { 1, 1 })
    ps.clear()
end)

if failed > 0 then
    print(failed .. " test(s) FAILED")
    os.exit(1)
end
print("all tests passed")
