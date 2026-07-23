-- Third offline tier: paths where a *Vim* error (not a Lua one) would escape
-- into the prompt loop and abort the search half-done.
--
-- These only work because run.sh drives specs with `nvim -l`. Measured: under
-- `-c "luafile"` a Vim error raised inside vim.fn.* never becomes a Lua error
-- -- expand("<cword>") on a blank line just returns "" -- so every test here
-- passes with the guards removed. Both tests below were checked the other way
-- round too: unguard either call and that test, and only that test, fails.
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

local function cursor()
    return vim.api.nvim_win_get_cursor(0)
end

local function type_keys(keys)
    -- "t": handled as typed -- a mapped <Esc> in the cmdline would act like <CR>
    -- (:h c_<Esc>), and the prompt's own temporary c-mode maps must fire
    vim.fn.feedkeys(vim.keycode(keys), "t")
end

local ps = require("pcre")

-- <cword>/<cWORD> raise E348 when there is no word under the cursor. Unguarded
-- that escapes search(), so the prompt never accepts and the cursor stays put:
-- the assertion is that the rest of the typed pattern still lands and searches.

t("search: <C-r><C-w> on a blank line inserts nothing instead of throwing", function()
    show({ "   ", "needle" }, { 1, 1 })
    type_keys("<C-r><C-w>needle<CR>")
    ps.search()
    eq(cursor(), { 2, 0 })
end)

t("search: <C-r><C-a> on a blank line inserts nothing instead of throwing", function()
    show({ "   ", "needle" }, { 1, 1 })
    type_keys("<C-r><C-a>needle<CR>")
    ps.search()
    eq(cursor(), { 2, 0 })
end)

if failed > 0 then
    print(("%d test(s) FAILED"):format(failed))
    vim.cmd("cq")
end
print("all tests passed")
