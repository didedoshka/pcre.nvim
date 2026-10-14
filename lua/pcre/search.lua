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
local bit = require("bit")

local M = {}

local last = nil ---@type string? last accepted pattern
local owned = nil ---@type string? @/ as we left it, to detect a native search
local forward = true ---@type boolean direction of the owned search (like v:searchforward)

---The one live (painted) search; nil = no highlights anywhere. prompt marks
---the incremental preview while typing: the current match paints IncSearch
---(not CurSearch), and the other matches only when 'hlsearch' is on -- native
---'incsearch' behaves exactly so.
---@type { buf: integer, pattern: string, cur: pcre2.Match?, prompt: boolean? }?
local live = nil
local painted = {} ---@type table<integer, integer[]> win -> matchaddpos ids

-- The current match is anchored to an extmark, not to the coordinates it had
-- when the search landed: native CurSearch follows the text through an edit
-- (measured -- typing the pattern itself at the cursor leaves the highlight on
-- the original match, pushed right, and paints the typed cells plain Search).
-- Right gravity is what does that pushing, so the default is the one we want.
local cur_ns = vim.api.nvim_create_namespace("pcre.cursearch")
local cur_mark = nil ---@type integer? extmark id in live.buf

---Replace the live search, re-anchoring the current match with it.
---@param next_live table? the new live search, nil to drop everything
local function set_live(next_live)
    -- restoring the search that is already live (the prompt's empty-pattern
    -- and cancel paths): keep its mark -- the mark tracked edits, while
    -- live.cur still holds the coordinates the match had when the search
    -- landed, which an edit can push out of range (nvim_buf_set_extmark
    -- E5108, measured)
    if next_live ~= nil and next_live == live then
        return
    end
    if cur_mark and live and vim.api.nvim_buf_is_valid(live.buf) then
        vim.api.nvim_buf_del_extmark(live.buf, cur_ns, cur_mark)
    end
    cur_mark = nil
    live = next_live
    if live and live.cur and vim.api.nvim_buf_is_valid(live.buf) then
        cur_mark = vim.api.nvim_buf_set_extmark(live.buf, cur_ns,
            live.cur.lnum - 1, live.cur.scol, {})
    end
end

---Where the current match sits now, or nil with no current match at all.
---@return { lnum: integer, scol: integer }?
local function cur_at()
    if not (live and live.cur and cur_mark) then
        return nil
    end
    local p = vim.api.nvim_buf_get_extmark_by_id(live.buf, cur_ns, cur_mark, {})
    return p[1] and { lnum = p[1] + 1, scol = p[2] } or nil
end

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
    local cur = cur_at()
    local ids, pos = {}, {}
    local function flush(group, prio)
        if #pos > 0 then
            ids[#ids + 1] = vim.fn.matchaddpos(group, pos, prio, -1, { window = win })
            pos = {}
        end
    end
    -- 'incsearch' without 'hlsearch' shows the current match alone, like native
    local others = not (live.prompt and not vim.o.hlsearch)
    local cur_pos = nil
    for _, m in ipairs(matches) do
        local lnum = top + m.lnum - 1
        -- zero-width matches get one visible cell, like native hlsearch
        local item = { lnum, m.scol + 1, math.max(m.ecol - m.scol, 1) }
        if cur and lnum == cur.lnum and m.scol == cur.scol then
            -- the anchored match, sized by this find (an edit inside it
            -- changes its length); with nothing matching at the anchor any
            -- more, no match is current and nothing wears CurSearch
            cur_pos = item
        elseif others then
            pos[#pos + 1] = item
            if #pos == 8 then -- matchaddpos takes at most 8 positions per call
                flush("Search", 10)
            end
        end
    end
    flush("Search", 10)
    if cur_pos then
        pos = { cur_pos }
        flush(live.prompt and "IncSearch" or "CurSearch", 11)
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
---backward records the search direction: n repeats it, N reverses it, like
---native n/N after `#` or `?` (measured), and v:searchforward mirrors it for
---anything native that reads the variable.
local function own(pattern, backward)
    last = pattern
    forward = not backward
    vim.fn.setreg("/", pattern)
    vim.v.hlsearch = 0 -- setreg alone turns highlighting back on
    vim.v.searchforward = forward and 1 or 0
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
    set_live(nil)
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

---The native search echo, all measured: the pattern prefixed with the search
---direction (? for the # family), plus a right-aligned [cur/total] -- "W
---[cur/total]" after a wrap -- unless 'shortmess' has S. With S the wrap
---falls back to the old warning line, which the s flag silences in turn; the
---warning names the jump direction, not the search's.
local function echo_search(pattern, cur, total, wrapped, jump_backward)
    local ss = vim.o.shortmess
    local text = (forward and "/" or "?") .. pattern
    if ss:find("S", 1, true) then
        if wrapped and not ss:find("s", 1, true) then
            echo({ { jump_backward and "search hit TOP, continuing at BOTTOM"
                or "search hit BOTTOM, continuing at TOP", "WarningMsg" } })
        else
            echo({ { text } })
        end
        return
    end
    local chunks = { { text } }
    local count = ((wrapped and "W [%d/%d]" or "[%d/%d]")):format(cur or 0, total)
    -- keep clear of the 'showcmd' cells at the end of the last line: a message
    -- reaching into them triggers a hit-enter prompt (measured on 0.13-dev,
    -- threshold columns-12 with showcmd, columns-1 without); native search
    -- counts sit left of that area too
    local reserved = vim.o.showcmd and 12 or 1
    local pad = vim.o.columns - vim.api.nvim_strwidth(text) - #count - reserved
    chunks[#chunks + 1] = { (pad >= 1 and string.rep(" ", pad) or " ") .. count }
    echo(chunks)
end

---Interactive prompt on the real cmdline (vim.fn.input), so the cursor in the
---prompt IS the native cursor -- blink, guicursor shape, <Left>/<Right>,
---<C-u>/<C-w>/<C-r>, pastes are all native cmdline editing. An echoed
---facsimile can't do that: a "Cursor"-highlighted cell neither blinks nor
---takes the ci cursor shape (measured; two earlier attempts). Only the
---incremental matching (CmdlineChanged) and search history (input() would use
---the "@" history) are ours.
---@class pcre.DirOpts
---@field backward? boolean the "?"/"#"/"gN" flavour of the mapping

---@param opts? pcre.DirOpts backward is the "?" prompt
function M.search(opts)
    local backward = (opts or {}).backward or false
    local count = vim.v.count1 -- [count]/pat accepts the count'th match, like native
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local view = vim.fn.winsaveview()
    local matches = {} ---@type pcre2.Match[]
    local cur = nil ---@type integer?
    local cycled = false -- <C-g>/<C-t> picked cur; accept keeps it over nearest()
    local hlsearch = vim.v.hlsearch -- native highlights, hidden while we type
    local prev_live = live -- what was painted before the prompt, for cancel

    -- Native incsearch scrolls from inside the cmdline loop and WinScrolled
    -- still fires per keystroke; inside vim.fn.input() nvim fires none
    -- (measured: 3 events natively while typing, 0 here). Everything that
    -- redraws per viewport misses the scrolled-in lines until <CR> -- LSP
    -- semantic tokens above all: their range request hangs off WinScrolled.
    -- So fire it ourselves whenever the prompt moves the view. Scheduled, not
    -- inline: fired from the CmdlineChanged callback, the handlers saw that
    -- event's v:event ({cmdlevel, cmdtype}) and read it as window ids, which
    -- crashed arc.nvim's (measured; nvim_exec_autocmds cannot set v:event and
    -- reports a handler's error itself, so a pcall around it caught nothing).
    -- The scheduled call still runs while input() waits for the next key, with
    -- v:event empty (measured in a PTY); the redraw paints what the handlers
    -- drew under the open cmdline, as the inline call's trailing redraw did.
    local function view_key()
        local v = vim.fn.winsaveview()
        return v.topline .. ":" .. v.leftcol
    end
    local view_at = view_key()
    local function notify_scroll()
        local now = view_key()
        if now ~= view_at then
            view_at = now
            vim.schedule(function()
                if vim.api.nvim_win_is_valid(win) then
                    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
                    vim.cmd("redraw")
                end
            end)
        end
    end

    local function update(pattern)
        matches = pattern ~= "" and M.find(buf, pattern) or {}
        -- a regex error mid-typing (unclosed group etc.) just means no matches yet
        matches = matches or {}
        cur = nearest(matches, view.lnum, view.col, backward)
        cycled = false -- the pattern changed under the cycling
        if not vim.o.incsearch then
            -- native without 'incsearch': no jump, no highlights while typing
            return
        end
        if cur then
            vim.api.nvim_win_set_cursor(win, { matches[cur].lnum, matches[cur].scol })
        else
            vim.fn.winrestview(view)
        end
        -- empty pattern shows whatever was on screen before, like native
        set_live(pattern ~= ""
            and { buf = buf, pattern = pattern, cur = matches[cur], prompt = true }
            or prev_live)
        M.repaint()
        notify_scroll()
        vim.cmd("redraw") -- paint under the open cmdline, like native incsearch
    end

    ---c_CTRL-G / c_CTRL-T: move the current match while typing (:h c_CTRL-G;
    ---'incsearch' only, 'wrapscan' applies). <C-g> follows the search
    ---direction, so it cycles backward under a "?" prompt. The accepted
    ---search lands on the cycled match instead of the one nearest the origin.
    local function cycle(delta)
        if not vim.o.incsearch or not cur then
            return
        end
        local idx = cur + (backward and -delta or delta)
        if idx < 1 or idx > #matches then
            if not vim.o.wrapscan then
                return
            end
            idx = (idx - 1) % #matches + 1
        end
        cur = idx
        cycled = true
        vim.api.nvim_win_set_cursor(win, { matches[cur].lnum, matches[cur].scol })
        set_live({ buf = buf, pattern = vim.fn.getcmdline(), cur = matches[cur], prompt = true })
        M.repaint()
        notify_scroll()
        vim.cmd("redraw")
    end

    ---@param keep_live boolean put the pre-prompt highlights back (plain
    ---cancel) or drop everything (failed search: nothing matches anyway)
    local function cancel(keep_live)
        set_live(keep_live and prev_live or nil)
        M.repaint()
        vim.fn.winrestview(view)
        notify_scroll()
        vim.v.hlsearch = hlsearch
        echo({})
    end

    local group = vim.api.nvim_create_augroup("pcre.prompt", { clear = true })
    vim.api.nvim_create_autocmd("CmdlineChanged", {
        group = group,
        callback = function()
            if vim.fn.getcmdtype() == "@" then
                update(vim.fn.getcmdline())
            end
        end,
    })

    -- input() reads and writes the "@" history; a search prompt must use the
    -- search history, so these four take it over for the prompt's lifetime
    -- (input() is modal, no other cmdline can run meanwhile)
    local hist = { pos = 0, stash = "" }
    local function hist_move(delta)
        if hist.pos == 0 then
            if delta < 0 then
                return
            end
            hist.stash = vim.fn.getcmdline()
        end
        local pos = hist.pos + delta
        local entry = pos == 0 and hist.stash or vim.fn.histget("search", -pos)
        if pos < 0 or entry == "" and pos > 0 then
            return -- past the oldest entry: stay, like native
        end
        hist.pos = pos
        vim.fn.setcmdline(entry)
    end
    local function insert_at_cmdpos(text)
        local line, pos = vim.fn.getcmdline(), vim.fn.getcmdpos()
        vim.fn.setcmdline(line:sub(1, pos - 1) .. text .. line:sub(pos), pos + #text)
    end
    -- <cword>/<cWORD> raise E348 on a blank line (verified), which would abort
    -- the whole prompt; guard and treat "no word" as an empty insert. The
    -- incsearch jump has moved the cursor to the current match, so like native
    -- c_CTRL-R_CTRL-W this picks up the word being matched.
    local function insert_cursor_text(what)
        local ok, text = pcall(vim.fn.expand, what)
        insert_at_cmdpos(ok and text or "")
    end
    local cmaps = {
        ["<Up>"] = function() hist_move(1) end,
        ["<C-p>"] = function() hist_move(1) end,
        ["<Down>"] = function() hist_move(-1) end,
        ["<C-n>"] = function() hist_move(-1) end,
        ["<C-g>"] = function() cycle(1) end,
        ["<C-t>"] = function() cycle(-1) end,
        -- backspace past an empty pattern leaves the search, like native "/"
        -- (input() would just sit there). <C-c>, not <Esc>: an <Esc> coming
        -- from a mapping executes the cmdline instead of quitting (:h c_<Esc>)
        ["<BS>"] = function()
            return vim.fn.getcmdline() == "" and "<C-c>" or "<BS>"
        end,
        -- native c_CTRL-R would insert a multiline register with literal ^M;
        -- the pattern is one line, so newlines flatten to spaces instead
        ["<C-r>"] = function()
            local ok, reg = pcall(vim.fn.getcharstr) -- pcall: <C-c> raises
            if not ok then
                return
            end
            if reg == vim.keycode("<C-w>") then
                insert_cursor_text("<cword>")
            elseif reg == vim.keycode("<C-a>") then
                insert_cursor_text("<cWORD>")
            elseif reg == vim.keycode("<C-l>") then
                insert_at_cmdpos(vim.api.nvim_get_current_line())
            elseif #reg == 1 then
                insert_at_cmdpos((vim.fn.getreg(reg):gsub("\n", " ")))
            end
        end,
    }
    for lhs, fn in pairs(cmaps) do
        vim.keymap.set("c", lhs, fn, { expr = lhs == "<BS>" })
    end

    local saved_paste = vim.paste
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.paste = function(plines, _)
        -- a terminal paste while prompting lands in the pattern; newlines
        -- flatten to spaces like <C-r> pastes, the pattern is one line
        insert_at_cmdpos(table.concat(plines, " "))
        return true
    end

    vim.v.hlsearch = 0
    update("")
    -- cancelreturn must be impossible to type; \1 can't land in a pattern
    local ok_in, pattern = pcall(vim.fn.input,
        { prompt = backward and "?" or "/", cancelreturn = "\1" })
    vim.paste = saved_paste
    for lhs in pairs(cmaps) do
        pcall(vim.keymap.del, "c", lhs)
    end
    vim.api.nvim_del_augroup_by_id(group)
    if not ok_in or pattern == "\1" then -- <Esc> (cancelreturn) or <C-c> (raises)
        cancel(true)
        return
    end
    if pattern == "" then
        local prev = pcre_last()
        if not prev then
            cancel(true)
            return
        end
        pattern = prev -- empty pattern repeats the last search, like native
    end
    vim.fn.histadd("search", pattern)
    matches = M.find(buf, pattern) or {}
    local wrapped = false
    if not cycled then -- a <C-g>/<C-t> pick beats the origin-nearest match
        cur = nil
        local lnum, col = view.lnum, view.col
        for _ = 1, count do
            local w
            cur, w = nearest(matches, lnum, col, backward)
            if not cur then
                break
            end
            wrapped = wrapped or w
            lnum, col = matches[cur].lnum, matches[cur].scol
        end
    end
    if not cur then
        cancel(false)
        own(pattern, backward) -- after cancel(): a failed search still owns n/N
        local msg = "E486: Pattern not found: " .. pattern
        if #matches > 0 then -- only a count under 'nowrapscan' can exhaust them
            msg = (backward and "E384: search hit TOP without match for: "
                or "E385: search hit BOTTOM without match for: ") .. pattern
        end
        echo({ { msg, "ErrorMsg" } })
        return
    end
    own(pattern, backward)
    local m = matches[cur]
    vim.fn.winrestview(view) -- jump from the origin, so m' lands there
    jump(win, m)
    set_live(vim.o.hlsearch and { buf = buf, pattern = pattern, cur = m } or nil)
    M.repaint()
    if wrapped then
        vim.api.nvim_exec_autocmds("SearchWrapped", {})
    end
    echo_search(pattern, cur, #matches, wrapped, backward)
end

---Jump to the [count]th nearest match of pat, from the cursor (n/N) or from
---an explicit {lnum, col} origin (the star family). pat must already be owned.
local function goto_nearest(pat, backward, count, from)
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local matches = M.find(buf, pat)
    if not matches or #matches == 0 then
        echo({ { "E486: Pattern not found: " .. pat, "ErrorMsg" } })
        return
    end
    local pos = from or vim.api.nvim_win_get_cursor(win)
    local lnum, col = pos[1], pos[2]
    local idx, wrapped
    for _ = 1, count do
        local w
        idx, w = nearest(matches, lnum, col, backward)
        if not idx then
            echo({ { backward and "E384: search hit TOP without match for: " .. pat
                or "E385: search hit BOTTOM without match for: " .. pat, "ErrorMsg" } })
            return
        end
        wrapped = wrapped or w
        lnum, col = matches[idx].lnum, matches[idx].scol
    end
    jump(win, matches[idx])
    set_live(vim.o.hlsearch and { buf = buf, pattern = pat, cur = matches[idx] } or nil)
    M.repaint()
    if wrapped then
        vim.api.nvim_exec_autocmds("SearchWrapped", {})
    end
    echo_search(pat, idx, #matches, wrapped, backward)
end

local function step(backward)
    local count = vim.v.count1
    local pat = pcre_last()
    if not pat then
        -- no pcre search yet: pass through, so n after a native search (a
        -- plugin's, gd, an unmapped *) keeps working
        local keys = (count > 1 and count or "") .. (backward and "N" or "n")
        local ok, err = pcall(vim.cmd.normal, { keys, bang = true })
        if not ok then
            echo({ { tostring(err):gsub("^.*Vim%(normal%):", ""), "ErrorMsg" } })
        end
        return
    end
    -- n repeats the search direction, N reverses it: after a backward search
    -- (#) they swap, like native (measured)
    goto_nearest(pat, backward == forward, count)
end

---Next match of the last search (an "n" mapping).
function M.next()
    step(false)
end

---Previous match of the last search (an "N" mapping).
function M.prev()
    step(true)
end

---PCRE2 metacharacters escaped so the word matches literally.
local function pcre_escape(s)
    return (s:gsub("[%^%$%.%|%?%*%+%(%)%[%]{}\\]", "\\%0"))
end

---The star-family pattern for the word under the cursor: escaped, and for the
---exact variants bounded by \b -- but only where the edge char is a word char
---*to PCRE2*. 'iskeyword' can put chars in <cword> that PCRE2's \w does not
---cover (a lisp "-", a "!"), and \b against a non-word edge demands a word
---char outside the match, so the word would never match itself. pcre2 probes
---its own \w (UTF + UCP, unicode-aware) instead of a Lua guess.
local function cword_pattern(exact)
    -- expand() raises E348 on a blank line (verified for <C-r><C-w> above);
    -- no word under the cursor is a nil pattern, not an error
    local ok, word = pcall(vim.fn.expand, "<cword>")
    if not ok or word == "" then
        return nil
    end
    local pat = pcre_escape(word)
    if exact then
        local head = pcre2.find({ word }, "^\\w") or {}
        local tail = pcre2.find({ word }, "\\w$") or {}
        pat = (#head > 0 and "\\b" or "") .. pat .. (#tail > 0 and "\\b" or "")
    end
    return pat
end

---@class pcre.CwordOpts
---@field backward? boolean previous occurrence instead of next ("#")
---@field exact? boolean word boundaries; false is the g* flavour (default true)

---Search for the word under the cursor as a pcre pattern (the "*"/"#"/"g*"/
---"g#" mappings), so star searches speak the same regex syntax as "/":
---\bword\b instead of the native \<word\>. Like "/", always case-sensitive --
---native * follows 'ignorecase', pcre patterns take (?i) instead.
---@param opts? pcre.CwordOpts
function M.search_cword(opts)
    opts = opts or {}
    local count = vim.v.count1
    local pat = cword_pattern(opts.exact ~= false)
    if not pat then
        echo({ { "E348: No string under cursor", "ErrorMsg" } })
        return
    end
    vim.fn.histadd("search", pat)
    own(pat, opts.backward)
    -- native * and # search from the start of the word, not from the cursor:
    -- measured, * on the whitespace before a word skips that word, and # from
    -- mid-word skips the current occurrence. So the origin is the match
    -- covering-or-after the cursor on its line (falling back to the cursor).
    local pos = vim.api.nvim_win_get_cursor(0)
    local from = nil
    local line = vim.api.nvim_buf_get_lines(0, pos[1] - 1, pos[1], false)
    for _, m in ipairs(pcre2.find(line, pat) or {}) do
        if m.ecol > pos[2] then
            from = { pos[1], m.scol }
            break
        end
    end
    goto_nearest(pat, opts.backward or false, count, from)
end

---Byte column of the last character of match m on line (multibyte-safe, the
---same continuation-byte walk as pcre2.find); a zero-width match gets one
---cell, like everywhere else.
local function match_end_col(line, m)
    local col = math.max(m.ecol - 1, m.scol)
    while col > m.scol and bit.band(line:byte(col + 1) or 0, 0xC0) == 0x80 do
        col = col - 1
    end
    return col
end

local function line_of(buf, lnum)
    return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
end

---Advance idx count-1 steps through matches in the search direction, wrapping
---per 'wrapscan'; nil when the count runs off an edge without it.
local function advance(matches, idx, count, backward)
    local step_ = backward and -1 or 1
    for _ = 2, count do
        local nxt = idx + step_
        if nxt < 1 or nxt > #matches then
            if not vim.o.wrapscan then
                return nil
            end
            nxt = (nxt - 1) % #matches + 1
        end
        idx = nxt
    end
    return idx
end

---gn/gN: operate on the last search's match. Normal and operator-pending
---mode select the match under the cursor, else the next one in the search
---direction, as a charwise visual selection -- an operator then applies to
---it, and "." re-fires this mapping on the following match, which is exactly
---native cgn (measured). Visual mode moves the cursor to the match edge
---strictly past it in the direction, extending the selection (measured on
---native v_gn/v_gN). With no pcre search owned, falls through to native.
---@param opts? pcre.DirOpts
function M.select_match(opts)
    opts = opts or {}
    local backward = opts.backward or false
    local count = vim.v.count1
    local pat = pcre_last()
    if not pat then
        -- native gn reads @/ with vim's own engine
        local ok, err = pcall(vim.cmd.normal, { backward and "gN" or "gn", bang = true })
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
    local idx
    if vim.fn.mode(true):match("^[vV\22]") then
        -- the far edge strictly past the cursor: a cursor already sitting on
        -- a match's edge extends to the next match, like native
        if backward then
            for i = #matches, 1, -1 do
                local m = matches[i]
                if m.lnum < pos[1] or (m.lnum == pos[1] and m.scol < pos[2]) then
                    idx = i
                    break
                end
            end
        else
            for i, m in ipairs(matches) do
                if m.lnum > pos[1] or (m.lnum == pos[1]
                        and match_end_col(line_of(buf, m.lnum), m) > pos[2]) then
                    idx = i
                    break
                end
            end
        end
        idx = idx or (vim.o.wrapscan and (backward and #matches or 1) or nil)
        idx = idx and advance(matches, idx, count, backward)
        if not idx then
            return
        end
        local m = matches[idx]
        local col = backward and m.scol or match_end_col(line_of(buf, m.lnum), m)
        vim.api.nvim_win_set_cursor(win, { m.lnum, col })
    else
        -- normal / operator-pending: the covering match, else the nearest one
        for i, m in ipairs(matches) do
            if m.lnum == pos[1] and m.scol <= pos[2]
                and pos[2] < math.max(m.ecol, m.scol + 1) then
                idx = i
                break
            end
        end
        idx = idx or nearest(matches, pos[1], pos[2], backward)
        idx = idx and advance(matches, idx, count, backward)
        if not idx then
            echo({ { backward and "E384: search hit TOP without match for: " .. pat
                or "E385: search hit BOTTOM without match for: " .. pat, "ErrorMsg" } })
            return
        end
        local m = matches[idx]
        -- gN anchors at the match end with the cursor on its start (measured)
        local head, tail = m.scol, match_end_col(line_of(buf, m.lnum), m)
        if backward then
            head, tail = tail, head
        end
        vim.cmd("normal! m'") -- gn is a jump, like n
        vim.api.nvim_win_set_cursor(win, { m.lnum, head })
        vim.cmd("normal! v")
        vim.api.nvim_win_set_cursor(win, { m.lnum, tail })
    end
    set_live(vim.o.hlsearch and { buf = buf, pattern = pat, cur = matches[idx] } or nil)
    M.repaint()
end

---The visual "*"/"#" (nvim's default v_star): search for the selection as
---literal text, from the selection start, leaving visual mode -- all like
---native (measured), except the pattern is a pcre escape instead of \V, and
---a multi-line selection is refused (the engine matches line by line).
---@param opts? pcre.DirOpts
function M.search_selection(opts)
    opts = opts or {}
    local count = vim.v.count1
    local vpos = vim.fn.getpos("v")
    local cpos = vim.fn.getpos(".")
    local region = vim.fn.getregion(vpos, cpos, { type = vim.fn.mode() })
    vim.cmd([[execute "normal! \<Esc>"]]) -- native v_* drops the selection
    if #region ~= 1 then
        echo({ { "pcre: multi-line selection search is not supported", "ErrorMsg" } })
        return
    end
    local first = (vpos[2] < cpos[2] or (vpos[2] == cpos[2] and vpos[3] <= cpos[3]))
        and vpos or cpos
    local pat = pcre_escape(region[1])
    vim.fn.histadd("search", pat)
    own(pat, opts.backward)
    goto_nearest(pat, opts.backward or false, count, { first[2], first[3] - 1 })
end

---A pattern accepted outside the prompt: ":S" owns the search the way native
---":s" does (measured) -- @/ is set even when nothing matched, highlights
---relight, n/N repeat it forward, nothing lands in the search history.
function M.adopt(pattern)
    own(pattern)
    set_live(vim.o.hlsearch
        and { buf = vim.api.nvim_get_current_buf(), pattern = pattern } or nil)
    M.repaint()
end

---The owned pcre pattern, or nil once a native search took @/ over (":S//"
---reuses it, like native ":s//" reuses the last search pattern).
function M.last_pattern()
    return pcre_last()
end

return M
