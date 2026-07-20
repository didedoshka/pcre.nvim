-- Shared rg plumbing. Everything runs synchronously: the input is one buffer's
-- text (a few ms at worst), and the search prompt blocks in getcharstr() anyway,
-- so async completions could never be delivered mid-prompt.
local M = {}

-- rg exit codes: 0 = matches, 1 = no matches, 2 = error (bad pattern etc).

---Run rg --json over text; returns the decoded event stream.
---@param args string[] extra args, ending with "--" and the pattern
---@param text string
---@return table[]? events, string? err
function M.json(args, text)
    local cmd = { "rg", "--json", "--pcre2", "--no-config" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { stdin = text }):wait()
    if res.code > 1 then
        return nil, vim.trim(res.stderr or "")
    end
    local events = {}
    for line in vim.gsplit(res.stdout or "", "\n", { trimempty = true }) do
        local ok, ev = pcall(vim.json.decode, line)
        if ok then
            events[#events + 1] = ev
        end
    end
    return events
end

---Run rg -o -r <template> over text: one output line per match, holding the
---template expanded against that match's capture groups.
---@param args string[] extra args including -r, ending with "--" and the pattern
---@param text string
---@return string[]? expansions, string? err
function M.expand(args, text)
    local cmd = { "rg", "--pcre2", "--no-config", "--color=never", "--no-filename",
        "--no-line-number", "--no-heading", "-o" }
    vim.list_extend(cmd, args)
    local res = vim.system(cmd, { stdin = text }):wait()
    if res.code > 1 then
        return nil, vim.trim(res.stderr or "")
    end
    local out = vim.split(res.stdout or "", "\n")
    -- the final newline, not an empty expansion
    if out[#out] == "" then
        table.remove(out)
    end
    return out
end

return M
