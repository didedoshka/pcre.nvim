-- ":S" -- vim's :s with PCRE2. One in-process pass: pcre2.find matches and
-- expands the replacement per match (pcre2_substitute against the live match
-- data), so positions and expansions can never disagree.
local pcre2 = require("pcre.pcre2")

local M = {}

local ns = vim.api.nvim_create_namespace("pcre.substitute")

---@class psub.Spec
---@field pat string
---@field repl string as typed
---@field flags table<string, true> subset of g, c, i

---Parse "/pattern/replacement/flags" (any non-alphanumeric separator, vim-style).
---@param args string
---@return psub.Spec? spec, string? err
function M.parse(args)
    local sep = args:sub(1, 1)
    if sep == "" or sep:match("[%w\\\"|]") then
        return nil, "expected :S/pattern/replacement/flags"
    end
    local parts = { "" }
    local i = 2
    while i <= #args do
        local c = args:sub(i, i)
        if c == "\\" and args:sub(i + 1, i + 1) == sep then
            parts[#parts] = parts[#parts] .. sep
            i = i + 2
        elseif c == sep and #parts < 3 then
            parts[#parts + 1] = ""
            i = i + 1
        else
            parts[#parts] = parts[#parts] .. c
            i = i + 1
        end
    end
    if parts[1] == "" then
        return nil, "empty pattern"
    end
    local flags = {}
    for f in (parts[3] or ""):gmatch(".") do
        if not ("gci"):find(f, 1, true) then
            return nil, "unsupported flag: " .. f
        end
        flags[f] = true
    end
    return { pat = parts[1], repl = parts[2] or "", flags = flags }
end

---Canonicalise the replacement for pcre2_substitute: digit groups become ${1}
---so adjacent text can never smear into the group name, and vim-style \1..\9
---and \0 are accepted too. "$$" stays a literal "$", "\\" a literal backslash.
---@param repl string
---@return string
function M.normalize_repl(repl)
    local out = {}
    local i = 1
    while i <= #repl do
        local c = repl:sub(i, i)
        local nxt = repl:sub(i + 1, i + 1)
        if c == "$" and nxt == "$" then
            out[#out + 1] = "$$"
            i = i + 2
        elseif c == "$" and nxt:match("%d") then
            local digits = repl:match("^%d+", i + 1)
            out[#out + 1] = "${" .. digits .. "}"
            i = i + 1 + #digits
        elseif c == "\\" and nxt == "\\" then
            out[#out + 1] = "\\"
            i = i + 2
        elseif c == "\\" and nxt:match("%d") then
            out[#out + 1] = "${" .. nxt .. "}"
            i = i + 2
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

---@class psub.Edit
---@field lnum integer 1-based absolute buffer line
---@field scol integer 0-based start byte column
---@field ecol integer 0-based end byte column, exclusive
---@field text string replacement

---All edits for spec over [line1, line2], in buffer order.
---@return psub.Edit[]? edits, string? err
function M.compute(buf, line1, line2, spec)
    local lines = vim.api.nvim_buf_get_lines(buf, line1 - 1, line2, false)
    local matches, err = pcre2.find(lines, spec.pat,
        { caseless = spec.flags.i, repl = M.normalize_repl(spec.repl) })
    if not matches then
        return nil, err
    end
    local edits = {}
    local seen = {} ---@type table<integer, true> lines that already have an edit
    for _, m in ipairs(matches) do
        -- vim semantics: without /g only the first match on each line
        if spec.flags.g or not seen[m.lnum] then
            if m.text:find("\n", 1, true) then
                -- everything downstream (spans, preview) assumes one-line texts
                return nil, "replacement expanded to multiple lines; not supported"
            end
            edits[#edits + 1] = {
                lnum = line1 - 1 + m.lnum,
                scol = m.scol,
                ecol = m.ecol,
                text = m.text,
            }
        end
        seen[m.lnum] = true
    end
    return edits
end

---Post-edit highlight spans: per line, left to right, tracking the column
---drift earlier replacements on the same line cause.
---@return { lnum: integer, scol: integer, ecol: integer }[]
local function spans_after(edits)
    local spans = {}
    local delta, cur_lnum = 0, nil
    for _, e in ipairs(edits) do
        if e.lnum ~= cur_lnum then
            cur_lnum, delta = e.lnum, 0
        end
        local len = #vim.split(e.text, "\n")[1]
        spans[#spans + 1] = { lnum = e.lnum, scol = e.scol + delta, ecol = e.scol + delta + len }
        delta = delta + len - (e.ecol - e.scol)
    end
    return spans
end

---Apply edits bottom-up so earlier offsets stay valid.
local function apply(buf, win, edits)
    for i = #edits, 1, -1 do
        local e = edits[i]
        vim.api.nvim_buf_set_text(buf, e.lnum - 1, e.scol, e.lnum - 1, e.ecol,
            vim.split(e.text, "\n"))
    end
    local nlines, seen = 0, {}
    for _, e in ipairs(edits) do
        if not seen[e.lnum] then
            seen[e.lnum] = true
            nlines = nlines + 1
        end
    end
    if win then
        vim.api.nvim_win_set_cursor(win, { edits[#edits].lnum, edits[#edits].scol })
    end
    if nlines > vim.o.report then
        vim.api.nvim_echo({ { ("%d substitution%s on %d line%s"):format(
            #edits, #edits == 1 and "" or "s", nlines, nlines == 1 and "" or "s") } }, false, {})
    end
end

---The [c] flag: mark each match, ask y/n/a/q/l, return the accepted subset.
local function confirm(buf, win, edits)
    local keep = {}
    local i = 1
    while i <= #edits do
        local e = edits[i]
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(buf, ns, e.lnum - 1, e.scol,
            { end_col = e.ecol, hl_group = "IncSearch", strict = false })
        vim.api.nvim_win_set_cursor(win, { e.lnum, e.scol })
        vim.cmd("normal! zv")
        vim.cmd("redraw")
        vim.api.nvim_echo(
            { { ("replace with %s (y/n/a/q/l)?"):format(e.text), "Question" } }, false, {})
        local ok, key = pcall(vim.fn.getcharstr)
        key = ok and key or "q"
        if key == "y" then
            keep[#keep + 1] = e
            i = i + 1
        elseif key == "n" then
            i = i + 1
        elseif key == "a" then
            for j = i, #edits do
                keep[#keep + 1] = edits[j]
            end
            break
        elseif key == "l" then
            keep[#keep + 1] = e
            break
        elseif key == "q" or key == "\27" or key == vim.keycode("<C-c>") then
            break
        end
        -- any other key: ask again for the same match, like native :s///c
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_echo({}, false, {})
    return keep
end

---:S implementation (the user command callback).
function M.run(o)
    local spec, perr = M.parse(o.args)
    if not spec then
        return vim.notify(perr, vim.log.levels.ERROR)
    end
    local buf = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    local edits, cerr = M.compute(buf, o.line1, o.line2, spec)
    if not edits then
        return vim.notify(cerr or "PCRE2 failed", vim.log.levels.ERROR)
    end
    if #edits == 0 then
        return vim.notify("Pattern not found: " .. spec.pat, vim.log.levels.ERROR)
    end
    if spec.flags.c then
        edits = confirm(buf, win, edits)
        if #edits == 0 then
            return
        end
    end
    apply(buf, win, edits)
end

---'inccommand' preview for :S -- vim's own live-preview machinery does the rest.
function M.preview(o, preview_ns, preview_buf)
    local spec = M.parse(o.args)
    if not spec then
        return 0
    end
    local buf = vim.api.nvim_get_current_buf()
    local ok, edits = pcall(M.compute, buf, o.line1, o.line2, spec)
    if not ok or not edits or #edits == 0 then
        return 0
    end
    local spans = spans_after(edits)
    for i = #edits, 1, -1 do
        local e = edits[i]
        vim.api.nvim_buf_set_text(buf, e.lnum - 1, e.scol, e.lnum - 1, e.ecol,
            vim.split(e.text, "\n"))
    end
    for _, s in ipairs(spans) do
        vim.api.nvim_buf_set_extmark(buf, preview_ns, s.lnum - 1, s.scol,
            { end_col = s.ecol, hl_group = "Substitute", strict = false })
    end
    if preview_buf then
        local order, row_of = {}, {}
        for _, s in ipairs(spans) do
            if not row_of[s.lnum] then
                order[#order + 1] = s.lnum
                row_of[s.lnum] = true
            end
        end
        table.sort(order)
        local plines = {}
        for row, lnum in ipairs(order) do
            row_of[lnum] = row - 1
            plines[row] = ("|%d| %s"):format(lnum,
                vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "")
        end
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, plines)
        for _, s in ipairs(spans) do
            local pw = #tostring(s.lnum) + 3
            vim.api.nvim_buf_set_extmark(preview_buf, preview_ns, row_of[s.lnum], pw + s.scol,
                { end_col = pw + s.ecol, hl_group = "Substitute", strict = false })
        end
        return 2
    end
    return 1
end

return M
