-- The "/" replacement: a hand-rolled prompt loop that looks like native search
-- but matches with rg --pcre2. Highlights are extmarks; n/N re-run rg instead
-- of caching positions, so they stay correct after buffer edits (native n
-- re-evaluates the pattern too).
local rg = require("pcre.rg")

local M = {}

local ns = vim.api.nvim_create_namespace("pcre")
local last = nil ---@type string? last accepted pattern
local owned = nil ---@type string? @/ as we left it, to detect a native search

---Take over "the last search" from vim: `*`, `#` and any native search read and
---write @/, so ours goes there too, and vim's own highlighting goes off -- it
---would otherwise draw its reading of a pcre pattern on top of our extmarks.
---A later native search overwrites @/, which is how step() sees it lost n/N.
local function own(pattern)
    last = pattern
    vim.fn.setreg("/", pattern)
    vim.v.hlsearch = 0 -- setreg alone turns highlighting back on
    owned = vim.fn.getreg("/")
end

---@class pcre.Match
---@field lnum integer 1-based line
---@field scol integer 0-based start byte column
---@field ecol integer 0-based end byte column, exclusive

---All matches of pattern in buf, in buffer order.
---@param buf integer
---@param pattern string
---@return pcre.Match[]? matches, string? err
function M.find(buf, pattern)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local events, err = rg.json({ "--", pattern }, table.concat(lines, "\n") .. "\n")
    if not events then
        return nil, err
    end
    local matches = {}
    for _, ev in ipairs(events) do
        if ev.type == "match" then
            for _, sm in ipairs(ev.data.submatches) do
                matches[#matches + 1] =
                    { lnum = ev.data.line_number, scol = sm.start, ecol = sm["end"] }
            end
        end
    end
    return matches
end

local function highlight(buf, matches, cur)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, m in ipairs(matches) do
        vim.api.nvim_buf_set_extmark(buf, ns, m.lnum - 1, m.scol, {
            end_col = m.ecol,
            hl_group = i == cur and "CurSearch" or "Search",
            strict = false,
        })
    end
end

---Index of the first match strictly after (lnum, col), or strictly before when
---backward; wraps per 'wrapscan'. Strictly-after matches native "/" and "n".
---@return integer? idx, boolean wrapped
local function nearest(matches, lnum, col, backward)
    if #matches == 0 then
        return nil, false
    end
    if backward then
        for i = #matches, 1, -1 do
            local m = matches[i]
            if m.lnum < lnum or (m.lnum == lnum and m.scol < col) then
                return i, false
            end
        end
        return vim.o.wrapscan and #matches or nil, true
    end
    for i, m in ipairs(matches) do
        if m.lnum > lnum or (m.lnum == lnum and m.scol > col) then
            return i, false
        end
    end
    return vim.o.wrapscan and 1 or nil, true
end

local function jump(win, m)
    vim.cmd("normal! m'") -- "/" and n are jump commands
    vim.api.nvim_win_set_cursor(win, { m.lnum, m.scol })
    vim.cmd("normal! zv")
end

---Clear search highlights everywhere (the :noh hook and manual use).
function M.clear()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
    end
end

---Our last pattern, or nil once a native search (*, #, gd, ...) has taken @/
---over -- then it owns n/N, and its hlsearch highlights are on screen instead.
local function pcre_last()
    if last and vim.fn.getreg("/") ~= owned then
        last = nil
        M.clear()
    end
    return last
end

local function echo(chunks)
    vim.cmd("redraw")
    vim.api.nvim_echo(chunks, false, {})
end

---Interactive prompt: incremental highlight + view scroll while typing, like
---'incsearch'. Meant for a normal-mode "/" mapping.
function M.search()
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local view = vim.fn.winsaveview()
    local pattern = ""
    local cpos = 0 -- character index into pattern, for <Left>/<Right>
    local hist = { pos = 0, stash = "" }
    local matches = {} ---@type pcre.Match[]
    local cur = nil ---@type integer?
    local hlsearch = vim.v.hlsearch -- native highlights, hidden while we type

    -- Insert text at cpos, moving the cursor past it (typed chars, <C-r> paste).
    local function insert_at_cursor(text)
        local before = vim.fn.strcharpart(pattern, 0, cpos)
        local after = vim.fn.strcharpart(pattern, cpos, vim.fn.strchars(pattern) - cpos)
        pattern = before .. text .. after
        cpos = cpos + vim.fn.strchars(text)
    end

    -- <cword>/<cWORD> raise E348 on a blank line (verified); nothing in this
    -- loop catches it, so guard here and treat "no word" as an empty insert.
    local function cursor_text(what)
        local ok, text = pcall(vim.fn.expand, what)
        return ok and text or ""
    end

    local function update()
        matches = pattern ~= "" and M.find(buf, pattern) or {}
        -- a regex error mid-typing (unclosed group etc.) just means no matches yet
        matches = matches or {}
        cur = nearest(matches, view.lnum, view.col)
        if cur then
            vim.api.nvim_win_set_cursor(win, { matches[cur].lnum, matches[cur].scol })
        else
            vim.fn.winrestview(view)
        end
        highlight(buf, matches, cur)
        -- no rendered caret here: the live jump above already puts the real
        -- cursor on the current match, a second one in the echo area would
        -- be a duplicate ("Cursor" chunk here previously caused exactly that)
        echo({ { "/" .. pattern } })
    end

    local function cancel()
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        vim.fn.winrestview(view)
        vim.v.hlsearch = hlsearch
        echo({})
    end

    vim.v.hlsearch = 0
    update()
    while true do
        local ok, key = pcall(vim.fn.getcharstr) -- pcall: <C-c> raises
        if not ok then
            key = "\27"
        end
        if key == "\r" or key == "\n" then
            if pattern == "" then
                local prev = pcre_last()
                if not prev then
                    cancel()
                    return
                end
                pattern = prev -- empty pattern repeats the last search, like native
                update()
            end
            vim.fn.histadd("search", pattern)
            if not cur then
                cancel()
                own(pattern) -- after cancel(): a failed search still owns n/N
                echo({ { "E486: Pattern not found: " .. pattern, "ErrorMsg" } })
                return
            end
            own(pattern)
            local m = matches[cur]
            vim.fn.winrestview(view) -- jump from the origin, so m' lands there
            jump(win, m)
            if vim.o.hlsearch then
                highlight(buf, matches, cur)
            else
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            end
            echo({ { "/" .. pattern } })
            return
        elseif key == "\27" or key == vim.keycode("<C-c>") then
            cancel()
            return
        elseif key == vim.keycode("<BS>") or key == "\x80kb" or key == "\127" then
            if pattern == "" then -- backspace past empty leaves search, like native
                cancel()
                return
            end
            if cpos > 0 then
                local before = vim.fn.strcharpart(pattern, 0, cpos - 1)
                local after = vim.fn.strcharpart(pattern, cpos, vim.fn.strchars(pattern) - cpos)
                pattern = before .. after
                cpos = cpos - 1
                update()
            end
        elseif key == vim.keycode("<C-u>") then
            -- native semantics: clear from the start of line up to the cursor
            pattern = vim.fn.strcharpart(pattern, cpos, vim.fn.strchars(pattern) - cpos)
            cpos = 0
            update()
        elseif key == vim.keycode("<C-w>") then
            local before = vim.fn.strcharpart(pattern, 0, cpos)
            local after = vim.fn.strcharpart(pattern, cpos, vim.fn.strchars(pattern) - cpos)
            before = before:gsub("%s+$", ""):gsub("%S+$", "")
            cpos = vim.fn.strchars(before)
            pattern = before .. after
            update()
        elseif key == vim.keycode("<C-r>") then
            local rok, reg = pcall(vim.fn.getcharstr)
            if rok and reg == vim.keycode("<C-w>") then
                -- incsearch has moved the cursor to the current match, so like
                -- native c_CTRL-R_CTRL-W this picks up the word being matched
                insert_at_cursor(cursor_text("<cword>"))
            elseif rok and reg == vim.keycode("<C-a>") then
                insert_at_cursor(cursor_text("<cWORD>"))
            elseif rok and #reg == 1 then
                insert_at_cursor((vim.fn.getreg(reg):gsub("\n", " ")))
            end
            update()
        elseif key == vim.keycode("<Left>") then
            cpos = math.max(0, cpos - 1)
            update()
        elseif key == vim.keycode("<Right>") then
            cpos = math.min(vim.fn.strchars(pattern), cpos + 1)
            update()
        elseif key == vim.keycode("<Up>") or key == vim.keycode("<C-p>") then
            if hist.pos == 0 then
                hist.stash = pattern
            end
            local entry = vim.fn.histget("search", -(hist.pos + 1))
            if entry ~= "" then
                hist.pos = hist.pos + 1
                pattern = entry
                cpos = vim.fn.strchars(pattern)
                update()
            end
        elseif key == vim.keycode("<Down>") or key == vim.keycode("<C-n>") then
            if hist.pos > 0 then
                hist.pos = hist.pos - 1
                pattern = hist.pos == 0 and hist.stash
                    or vim.fn.histget("search", -hist.pos)
                cpos = vim.fn.strchars(pattern)
                update()
            end
        elseif key:byte(1) >= 32 and key:byte(1) ~= 128 then
            insert_at_cursor(key)
            update()
        end
        -- other special keys (mouse, ...): ignored
    end
end

local function step(backward)
    local pat = pcre_last()
    if not pat then
        -- no pcre search yet: pass through, so n after * or a plugin's native
        -- search keeps working
        local ok, err = pcall(vim.cmd.normal, { backward and "N" or "n", bang = true })
        if not ok then
            echo({ { tostring(err):gsub("^.*Vim%(normal%):", ""), "ErrorMsg" } })
        end
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local matches = M.find(buf, pat)
    if not matches or #matches == 0 then
        echo({ { "E486: Pattern not found: " .. pat, "ErrorMsg" } })
        return
    end
    local pos = vim.api.nvim_win_get_cursor(win)
    local idx, wrapped = nearest(matches, pos[1], pos[2], backward)
    if not idx then
        echo({ { backward and "E384: search hit TOP without match for: " .. pat
            or "E385: search hit BOTTOM without match for: " .. pat, "ErrorMsg" } })
        return
    end
    jump(win, matches[idx])
    if vim.o.hlsearch then
        highlight(buf, matches, idx)
    end
    if wrapped then
        echo({ { backward and "search hit TOP, continuing at BOTTOM"
            or "search hit BOTTOM, continuing at TOP", "WarningMsg" } })
    else
        echo({ { "/" .. pat } })
    end
end

---Next match of the last search (an "n" mapping).
function M.next()
    step(false)
end

---Previous match of the last search (an "N" mapping).
function M.prev()
    step(true)
end

return M
