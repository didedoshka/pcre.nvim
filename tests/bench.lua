-- Benchmark: how much does matching with in-process libpcre2 (LuaJIT FFI) cost
-- versus Vim's own regex engine? Every keystroke in the "/" prompt and every
-- n/N runs M.find(); this measures the like-for-like cost: one full-buffer
-- "find all matches" pass, pcre (FFI) against native (matchbufline, the same
-- engine incsearch uses).
--
-- Not part of the offline suite -- it's timing, not pass/fail, and takes a few
-- seconds. Run it by hand:  nvim --headless --clean --cmd "set rtp+=$PWD" -l tests/bench.lua
local search = require("pcre.search")

local function ms(ns) return ns / 1e6 end

-- Median wall time (ms) of fn over `iters` runs, after a warm-up run.
local function time(fn, iters)
    fn()
    local samples = {}
    for i = 1, iters do
        local t0 = vim.uv.hrtime()
        fn()
        samples[i] = vim.uv.hrtime() - t0
    end
    table.sort(samples)
    return ms(samples[math.ceil(#samples / 2)])
end

-- A buffer of `n` lines of plausible source text, with a predictable sprinkle
-- of matches so neither engine is scanning a haystack with no needle.
local function make_buf(n)
    local filler = {
        "local function handle_request(ctx, req)",
        "    if req.method == \"GET\" then",
        "        return ctx:respond(200, cache_lookup(req.path))",
        "    end",
        "    -- fall through to the slow path, TODO: memoise",
        "    local user = authenticate(req.headers.token)",
        "}",
    }
    local lines = {}
    for i = 1, n do
        lines[i] = filler[(i % #filler) + 1]
    end
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
end

-- Each case matches the *same* text under both engines, written in each
-- engine's own syntax, so the comparison is the engine + IPC, not the pattern.
local cases = {
    { label = "literal 'request'", pcre = "request",   vim = "request" },
    { label = "word \\w+",          pcre = "\\w+",       vim = "\\w\\+" },
    { label = "TODO w/ lookahead",  pcre = "TODO(?=:)",  vim = "TODO\\ze:" },
}

local sizes = { 100, 1000, 10000, 50000 }
local iters = 25

print(("pcre.nvim find-all benchmark  (nvim %s, libpcre2 FFI, median of %d)")
    :format(vim.version() and tostring(vim.version()) or "?", iters))
print(("%-22s %8s %10s %10s %8s"):format("case / lines", "matches", "pcre ms", "native ms", "x"))
print(string.rep("-", 62))

for _, c in ipairs(cases) do
    for _, n in ipairs(sizes) do
        local b = make_buf(n)
        local nmatch = #(search.find(b, c.pcre) or {})
        local pcre = time(function() search.find(b, c.pcre) end, iters)
        local native = time(function() vim.fn.matchbufline(b, c.vim, 1, "$") end, iters)
        print(("%-22s %8d %10.2f %10.2f %7.0fx")
            :format(("%s / %d"):format(c.label, n), nmatch, pcre, native, pcre / native))
        vim.api.nvim_buf_delete(b, { force = true })
    end
end

-- The fixed per-call floor: a one-line buffer isolates the buffer-read +
-- compile-cache-miss overhead that's paid on every keystroke regardless of size.
local b = make_buf(1)
local floor = time(function() search.find(b, "nomatch_xyzzy") end, iters)
print(string.rep("-", 62))
print(("per-call floor (1 line, 0 matches): %.2f ms -- paid per keystroke")
    :format(floor))
