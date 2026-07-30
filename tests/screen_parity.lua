-- Manual verify tier: drives real interactive nvim instances in a PTY and
-- compares the plugin's :s experience against native, screen cell by screen
-- cell (keystrokes over the terminal, probes over RPC -- the way nvim's own
-- UI tests work). Deliberately NOT part of run.sh: it needs a PTY and ~40 s.
--
--   nvim --headless --clean -l tests/screen_parity.lua
--
-- This tier exists because of two measured blind spots of the offline suite:
-- cmdpreview never engages headless (the E474-on-'inccommand' class of bug is
-- invisible there), and message retention across redraws only shows on a real
-- screen. Both bugs below were found by a human before this file existed.
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

local function eq(got, want, label)
    assert(vim.deep_equal(got, want), ("%s: got %s, want %s")
        :format(label or "eq", vim.inspect(got), vim.inspect(want)))
end

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- the driven instance: plugin (enter mode) or bare native, same buffer
local inner_path = vim.fn.tempname() .. ".lua"
local inner = io.open(inner_path, "w")
assert(inner, "cannot write the inner script")
inner:write([[
if os.getenv("PROBE_MODE") == "pcre" then
    vim.opt.rtp:append(os.getenv("PROBE_RTP"))
    require("pcre").setup({ substitute_abbrev = "enter" })
end
vim.o.inccommand = "nosplit"
vim.api.nvim_buf_set_lines(0, 0, -1, false,
    { "foo bar foo baz", "no match here", "foo tail" })
]])
inner:close()

local function start(mode)
    local addr = vim.fn.tempname()
    local job = vim.fn.jobstart(
        { "nvim", "--clean", "--listen", addr, "-S", inner_path },
        { pty = true, width = 80, height = 24, env = { PROBE_MODE = mode, PROBE_RTP = repo } })
    assert(vim.wait(8000, function() return vim.uv.fs_stat(addr) ~= nil end),
        "inner nvim (" .. mode .. ") did not come up")
    vim.wait(500)
    return { job = job, chan = vim.fn.sockconnect("pipe", addr, { rpc = true }) }
end

local function stop(s)
    pcall(vim.fn.chanclose, s.chan)
    pcall(vim.fn.jobstop, s.job)
end

---Type str into the instance's terminal, one key at a time like fingers do:
---batched sends skip the per-keystroke preview machinery (measured).
local function keys(s, str)
    for i = 1, #str do
        vim.fn.chansend(s.job, str:sub(i, i))
        vim.wait(100)
    end
end

local function lua_in(s, code)
    return vim.rpcrequest(s.chan, "nvim_exec_lua", code, {})
end

-- the first three screen rows plus the message/cmdline row, after a redraw
-- (so only retained content survives -- transient echoes must not count)
local grab = [[
    vim.cmd("redraw")
    local rows = {}
    for row = 1, 3 do
        local cells = {}
        for col = 1, 40 do cells[#cells + 1] = vim.fn.screenstring(row, col) end
        rows[#rows + 1] = "[" .. table.concat(cells) .. "]"
    end
    local c = {}
    for col = 1, 30 do c[#c + 1] = vim.fn.screenstring(vim.o.lines, col) end
    rows[#rows + 1] = "cmd[" .. table.concat(c) .. "]"
    return table.concat(rows, "\n")
]]

t("typing :s never errors (the E474 'inccommand' regression)", function()
    local s = start("pcre")
    -- a previous substitute makes a bare :s previewable, which is what
    -- engaged the native preview one keystroke before the first separator
    lua_in(s, [[vim.fn.setreg("/", "foo") vim.cmd("substitute/bar/BAR/")]])
    keys(s, ":s/fo")
    vim.fn.chansend(s.job, "\27")
    vim.wait(300)
    local msgs = lua_in(s, [[return vim.fn.execute("messages")]])
    stop(s)
    -- E1568 is the benign DSR/background-color warning every PTY job gets
    msgs = msgs:gsub("E1568[^\n]*", "")
    assert(not msgs:find("E%d+"), "errors while typing :s/fo:\n" .. msgs)
end)

t("every typing stage renders exactly like native", function()
    local stages = { "pattern", "repl", "g", "cancelled", "accepted" }
    local dumps = {}
    for _, mode in ipairs({ "native", "pcre" }) do
        local s = start(mode)
        local d = {}
        keys(s, ":%s/foo")
        d.pattern = lua_in(s, grab)
        keys(s, "/XY")
        d.repl = lua_in(s, grab)
        keys(s, "/g")
        d.g = lua_in(s, grab)
        vim.fn.chansend(s.job, "\27")
        vim.wait(300)
        d.cancelled = lua_in(s, grab)
        keys(s, ":%s/foo/XY/g\r")
        vim.wait(400)
        d.accepted = lua_in(s, grab)
        stop(s)
        dumps[mode] = d
    end
    for _, stage in ipairs(stages) do
        eq(dumps.pcre[stage], dumps.native[stage], stage)
    end
end)

t("a below-'report' accept keeps the typed :s line on screen, like native", function()
    local dumps = {}
    for _, mode in ipairs({ "native", "pcre" }) do
        local s = start(mode)
        keys(s, ":s/bar/B/\r")
        vim.wait(400)
        dumps[mode] = lua_in(s, grab)
        stop(s)
    end
    eq(dumps.pcre, dumps.native)
end)

os.remove(inner_path)
if failed > 0 then
    print(("%d screen-parity check(s) FAILED"):format(failed))
    vim.cmd("cq")
end
print("all screen-parity checks passed")
