-- pcre.nvim -- "/" search and ":s" substitute with PCRE2, matched by
-- ripgrep instead of vim's regex engine.
--
-- Deliberately non-invasive: setup() only registers the :S command and the
-- :noh hook. Searching is functions you map yourself, and the :s -> :S
-- cmdline abbreviation is opt-in.
local M = {}

local search = require("pcre.search")
local substitute = require("pcre.substitute")

M.search = search.search
M.next = search.next
M.prev = search.prev
M.clear = search.clear

---@class pcre.Opts
---@field substitute_abbrev? boolean expand a typed :s (with any range) into :S

---@param opts? pcre.Opts
function M.setup(opts)
    opts = opts or {}

    vim.api.nvim_create_user_command("S", substitute.run, {
        nargs = 1,
        range = true,
        preview = substitute.preview,
        desc = "PCRE2 substitute (rg --pcre2)",
    })

    -- :noh must clear our highlights too or the search won't feel native;
    -- CmdlineLeave is the only hook :nohlsearch fires.
    vim.api.nvim_create_autocmd("CmdlineLeave", {
        group = vim.api.nvim_create_augroup("pcre", {}),
        callback = function()
            if vim.v.event.cmdtype ~= ":" or vim.v.event.abort then
                return
            end
            local cmd = vim.fn.getcmdline():match("^%s*(%l+)%s*$")
            if cmd and #cmd >= 3 and ("nohlsearch"):sub(1, #cmd) == cmd then
                search.clear()
            end
        end,
    })

    if opts.substitute_abbrev then
        -- Expand a lone, possibly range-prefixed :s into :S so :%s// muscle
        -- memory lands on PCRE2. Not a real abbreviation: those never fire
        -- after a range (":s/" expands, ":%s/" does not -- measured), so the
        -- rewrite happens on CmdlineChanged the moment the separator is typed.
        -- Native :s stays reachable as :su -- letters before the "s" (or none
        -- after it) never match.
        vim.api.nvim_create_autocmd("CmdlineChanged", {
            group = vim.api.nvim_create_augroup("pcre.abbrev", {}),
            callback = function()
                if vim.fn.getcmdtype() ~= ":" then
                    return
                end
                local line = vim.fn.getcmdline()
                -- range chars, lowercase s, then a just-typed separator; the
                -- rewritten "S" can't match again, so no recursion
                local range, sep = line:match("^(%s*[%d%%,%.%$<>'+%-;]*)s([^%w%s\\\"|])$")
                if range then
                    vim.fn.setcmdline(range .. "S" .. sep)
                end
            end,
        })
    end
end

return M
