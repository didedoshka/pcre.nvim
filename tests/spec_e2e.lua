-- End-to-end parity of the prompt against native "/": a child nvim per
-- variant (plain, and with pcre owning "/") gets the *same* keystrokes, and a
-- CmdlineChanged autocmd in the child samples the cmdline text and cursor
-- position after every change. The two streams must be identical -- that is
-- the claim "the prompt edits like native", measured on the real cmdline.
-- What this cannot see: cursor blink and guicursor shape. Those are native by
-- construction (the prompt IS the cmdline, the cursor in it is the real one),
-- but they render in the terminal, invisible to any headless check.
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

local repo = vim.fn.fnamemodify(_G.arg[0], ":h:h")

---Feed keys to a fresh child nvim (typed, so maps fire) and collect
---{ cmdline, cmdpos } at every CmdlineChanged, plus the final mode and cursor.
---The keys must end the cmdline session, or the sampling request would be
---served mid-prompt.
local function drive(with_plugin, keys)
    local chan = vim.fn.jobstart(
        { "nvim", "--embed", "--clean", "-i", "NONE", "-n" }, { rpc = true })
    assert(chan > 0, "could not start child nvim")
    vim.rpcrequest(chan, "nvim_exec_lua", [[
        local repo, with_plugin, keys = ...
        vim.o.rtp = vim.o.rtp .. "," .. repo
        vim.o.incsearch = true
        vim.api.nvim_buf_set_lines(0, 0, -1, false,
            { "alpha foo", "beta bar foo", "π wörld" })
        if with_plugin then
            local ps = require("pcre")
            ps.setup({})
            vim.keymap.set("n", "/", ps.search)
        end
        _G.samples = {}
        vim.api.nvim_create_autocmd("CmdlineChanged", {
            callback = function()
                _G.samples[#_G.samples + 1] =
                    { vim.fn.getcmdline(), vim.fn.getcmdpos() }
            end,
        })
        vim.fn.feedkeys(vim.keycode(keys), "t")
    ]], { repo, with_plugin, keys })
    -- served once the child's typeahead is drained, i.e. the prompt is closed
    local out = vim.rpcrequest(chan, "nvim_exec_lua", [[
        return { samples = _G.samples, mode = vim.fn.mode(),
            cursor = vim.api.nvim_win_get_cursor(0) }
    ]], {})
    vim.fn.jobstop(chan)
    return out
end

local function parity(name, keys)
    t(name .. ": " .. vim.fn.keytrans(vim.keycode(keys)), function()
        local native = drive(false, keys)
        local ours = drive(true, keys)
        assert(vim.deep_equal(native.samples, ours.samples),
            ("cmdline streams differ:\nnative %s\nours   %s"):format(
                vim.inspect(native.samples), vim.inspect(ours.samples)))
        assert(native.mode == ours.mode,
            ("mode: native %q, ours %q"):format(native.mode, ours.mode))
        assert(vim.deep_equal(native.cursor, ours.cursor),
            ("cursor: native %s, ours %s"):format(
                vim.inspect(native.cursor), vim.inspect(ours.cursor)))
    end)
end

-- every sequence ends the prompt (<Esc> or an emptying <BS>); "foo" exists in
-- the child buffer so the accept paths land both variants on the same match
parity("arrows edit mid-pattern", "/abc<Left><Left>X<Esc>")
parity("<Right> returns to the end", "/ab<Left>X<Right>Y<Esc>")
parity("<BS> after <Left>", "/abc<Left><BS><Esc>")
parity("<C-u> clears up to the cursor", "/abcd<Left><Left><C-u><Esc>")
parity("<C-w> deletes the word before the cursor", "/foo bar<Left><C-w><Esc>")
parity("<BS> past empty leaves the search", "/ab<BS><BS><BS>")
parity("accepting jumps to the same match", "/foo<CR>")
parity("multibyte pattern", "/wö<Left>X<Esc>")

if failed > 0 then
    print(failed .. " test(s) FAILED")
    vim.cmd("cq")
end
print("all tests passed")
