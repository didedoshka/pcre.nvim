-- The "/" replacement: a hand-rolled prompt loop that looks like native search
-- but matches with PCRE2 (in-process, lua/pcre/pcre2.lua). n/N re-run the
-- pattern instead of caching positions, so they stay correct after buffer
-- edits (native n re-evaluates the pattern too).
--
-- Highlights are matchaddpos(), not extmarks: measured (probe over screenattr /
-- nvim__inspect_cell), sign linehl backgrounds win over char extmarks at every
-- priority, while match-stage highlights layer exactly like native hlsearch --
-- over a breakpoint line's background, under a visual selection. Painting is
-- per window and viewport-only, repainted on scroll/resize/switch/edit, so its
-- cost tracks the screen, never the match count.
local pcre2 = require("pcre.pcre2")

local M = {}

local last = nil ---@type string? last accepted pattern
local owned = nil ---@type string? @/ as we left it, to detect a native search

---The one live (painted) search; nil = no highlights anywhere.
---@type { buf: integer, pattern: string, cur: pcre2.Match? }?
local live = nil
local painted = {} ---@type table<integer, integer[]> win -> matchaddpos ids

local function unpaint(win)
    for _, id in ipairs(painted[win] or {}) do
        pcall(vim.fn.matchdelete, id, win)
    end
    painted[win] = nil
end

---Paint the visible part of one window from a fresh viewport-sized find.
local function paint(win)
    unpaint(win)
    if not live or vim.api.nvim_win_get_buf(win) ~= live.buf then
        return
    end
    local top, bot = vim.fn.line("w0", win), vim.fn.line("w$", win)
    local lines = vim.api.nvim_buf_get_lines(live.buf, top - 1, bot, false)
    local matches = pcre2.find(lines, live.pattern) or {}
    local cur = live.cur
    local ids, pos = {}, {}
    local function flush(group, prio)
        if #pos > 0 then
            ids[#ids + 1] = vim.fn.matchaddpos(group, pos, prio, -1, { window = win })
            pos = {}
        end
    end
    for _, m in ipairs(matches) do
        local lnum = top + m.lnum - 1
        if not (cur and lnum == cur.lnum and m.scol == cur.scol) then
            -- zero-width matches get one visible cell, like native hlsearch
            pos[#pos + 1] = { lnum, m.scol + 1, math.max(m.ecol - m.scol, 1) }
            if #pos == 8 then -- matchaddpos takes at most 8 positions per call
                flush("Search", 10)
            end
        end
    end
    flush("Search", 10)
    if cur and cur.lnum >= top and cur.lnum <= bot then
        pos = { { cur.lnum, cur.scol + 1, math.max(cur.ecol - cur.scol, 1) } }
        flush("CurSearch", 11)
    end
    painted[win] = ids
end

---Repaint every window (an autocmd hook: scroll, resize, buffer switch, edit).
function M.repaint()
    for win in pairs(painted) do
        if not vim.api.nvim_win_is_valid(win) then
            painted[win] = nil
        end
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        paint(win)
    end
end

---Take over "the last search" from vim: `*`, `#` and any native search read and
---write @/, so ours goes there too, and vim's own highlighting goes off -- it
---would otherwise draw its reading of a pcre pattern on top of our matches.
---A later native search overwrites @/, which is how step() sees it lost n/N.
local function own(pattern)
    last = pattern
    vim.fn.setreg("/", pattern)
    vim.v.hlsearch = 0 -- setreg alone turns highlighting back on
    owned = vim.fn.getreg("/")
end

---All matches of pattern in buf, in buffer order.
---@param buf integer
---@param pattern string
---@return pcre2.Match[]? matches, string? err
function M.find(buf, pattern)
    return pcre2.find(vim.api.nvim_buf_get_lines(buf, 0, -1, false), pattern)
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
    live = nil
    for win in pairs(painted) do
        unpaint(win)
    end
end

---Drop the pcre search entirely, not just its highlights: with no last pattern
---n/N fall through to native. `:noh` must not do this -- native n re-highlights
---after :noh -- so it is separate from clear().
function M.forget()
    last = nil
    M.clear()
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

---The native search echo: "/pat", and a right-aligned [cur/total] like
---'shortmess' without S shows. total == nil leaves the count out.
local function echo_search(pattern, cur, total)
    local text = "/" .. pattern
    if not total then
        echo({ { text } })
        return
    end
    local count = ("[%d/%d]"):format(cur or 0, total)
    -- keep clear of the 'showcmd' cells at the end of the last line: a message
    -- reaching into them triggers a hit-enter prompt (measured on 0.13-dev,
    -- threshold columns-12 with showcmd, columns-1 without); native search
    -- counts sit left of that area too
    local reserved = vim.o.showcmd and 12 or 1
    local pad = vim.o.columns - vim.api.nvim_strwidth(text) - #count - reserved
    echo({ { text }, { (pad >= 1 and string.rep(" ", pad) or " ") .. count } })
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
    local matches = {} ---@type pcre2.Match[]
    local cur = nil ---@type integer?
    local hlsearch = vim.v.hlsearch -- native highlights, hidden while we type
    local prev_live = live -- what was painted before the prompt, for cancel

    -- Insert text at cpos, moving the cursor past it (typed chars, pastes).
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
        if not vim.o.incsearch then
            -- native without 'incsearch' shows only the pattern while typing:
            -- no jump, no highlights, no count until <CR>
            echo_search(pattern)
            return
        end
        if cur then
            vim.api.nvim_win_set_cursor(win, { matches[cur].lnum, matches[cur].scol })
        else
            vim.fn.winrestview(view)
        end
        -- empty pattern shows whatever was on screen before, like native
        live = pattern ~= "" and { buf = buf, pattern = pattern, cur = matches[cur] }
            or prev_live
        M.repaint()
        -- no rendered caret here: the live jump above already puts the real
        -- cursor on the current match, a second one in the echo area would
        -- be a duplicate ("Cursor" chunk here previously caused exactly that)
        echo_search(pattern, cur, pattern ~= "" and #matches or nil)
    end

    ---@param keep_live boolean put the pre-prompt highlights back (plain
    ---cancel) or drop everything (failed search: nothing matches anyway)
    local function cancel(keep_live)
        live = keep_live and prev_live or nil
        M.repaint()
        vim.fn.winrestview(view)
        vim.v.hlsearch = hlsearch
        echo({})
    end

    vim.v.hlsearch = 0
    update()
    local saved_paste = vim.paste
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.paste = function(plines, _)
        -- a terminal paste while prompting lands in the pattern; newlines
        -- flatten to spaces like <C-r> pastes, the pattern is one line
        insert_at_cursor((table.concat(plines, " ")))
        update()
        return true
    end
    local ok_loop, loop_err = pcall(function()
        while true do
            local ok, key = pcall(vim.fn.getcharstr) -- pcall: <C-c> raises
            if not ok then
                key = "\27"
            end
            if key == "\r" or key == "\n" then
                if pattern == "" then
                    local prev = pcre_last()
                    if not prev then
                        cancel(true)
                        return
                    end
                    pattern = prev -- empty pattern repeats the last search, like native
                    update()
                end
                vim.fn.histadd("search", pattern)
                if not cur then
                    cancel(false)
                    own(pattern) -- after cancel(): a failed search still owns n/N
                    echo({ { "E486: Pattern not found: " .. pattern, "ErrorMsg" } })
                    return
                end
                own(pattern)
                local m = matches[cur]
                vim.fn.winrestview(view) -- jump from the origin, so m' lands there
                jump(win, m)
                live = vim.o.hlsearch and { buf = buf, pattern = pattern, cur = m } or nil
                M.repaint()
                echo_search(pattern, cur, #matches)
                return
            elseif key == "\27" or key == vim.keycode("<C-c>") then
                cancel(true)
                return
            elseif key == vim.keycode("<BS>") or key == "\x80kb" or key == "\127" then
                if pattern == "" then -- backspace past empty leaves search, like native
                    cancel(true)
                    return
                end
                if cpos > 0 then
                    local before = vim.fn.strcharpart(pattern, 0, cpos - 1)
                    local after = vim.fn.strcharpart(pattern, cpos,
                        vim.fn.strchars(pattern) - cpos)
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
                local after = vim.fn.strcharpart(pattern, cpos,
                    vim.fn.strchars(pattern) - cpos)
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
    end)
    vim.paste = saved_paste
    if not ok_loop then
        error(loop_err, 0)
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
        live = { buf = buf, pattern = pat, cur = matches[idx] }
    else
        live = nil
    end
    M.repaint()
    if wrapped then
        echo({ { backward and "search hit TOP, continuing at BOTTOM"
            or "search hit BOTTOM, continuing at TOP", "WarningMsg" } })
    else
        echo_search(pat, idx, #matches)
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
