-- pcre.nvim -- "/" search and ":s" substitute with PCRE2, matched in-process
-- (libpcre2 over LuaJIT FFI) instead of vim's regex engine.
--
-- Deliberately non-invasive: setup() only registers the :S and :Pcre commands
-- and the :noh + repaint hooks. Searching is functions you map yourself, and
-- the :s -> :S cmdline abbreviation is opt-in.
local M = {}

local pcre2 = require("pcre.pcre2")
local search = require("pcre.search")
local substitute = require("pcre.substitute")

M.next = search.next
M.prev = search.prev
M.clear = search.clear

local enabled = true

---Whether pcre currently owns "/" and a typed ":s" (for a statusline).
function M.enabled()
    return enabled
end

---Turn pcre off and back on (also :Pcre), to run the same pattern through vim's
---own regex engine without editing the config. While off, "/" and a typed ":s"
---are the native ones; ":S" still substitutes with PCRE2, so the two are
---comparable side by side.
function M.toggle()
    enabled = not enabled
    -- n/N need no check of their own: with the pcre search forgotten they
    -- already fall through to native.
    if not enabled then
        search.forget()
    end
    vim.api.nvim_echo({ { "pcre " .. (enabled and "on" or "off") } }, false, {})
end

---The "/" and "?" mappings (normal, visual and operator-pending mode alike:
---the prompt keeps a visual selection alive, and in operator-pending mode
---the accepted jump is the motion).
---@param opts? pcre.DirOpts
function M.search(opts)
    if not enabled then
        -- "n": the "/" mapping itself must not fire again
        vim.api.nvim_feedkeys((opts or {}).backward and "?" or "/", "n", false)
        return
    end
    search.search(opts)
end

---The "gn"/"gN" mappings.
---@param opts? pcre.DirOpts
function M.select_match(opts)
    if not enabled then
        local count = vim.v.count > 0 and tostring(vim.v.count) or ""
        vim.api.nvim_feedkeys(count .. ((opts or {}).backward and "gN" or "gn"), "n", false)
        return
    end
    search.select_match(opts)
end

---The visual-mode "*"/"#" mappings.
---@param opts? pcre.DirOpts
function M.search_selection(opts)
    if not enabled then
        local count = vim.v.count > 0 and tostring(vim.v.count) or ""
        vim.api.nvim_feedkeys(count .. ((opts or {}).backward and "#" or "*"), "n", false)
        return
    end
    search.search_selection(opts)
end

---The "*"/"#"/"g*"/"g#" mappings: pcre search for the word under the cursor.
---@param opts? pcre.CwordOpts
function M.search_cword(opts)
    if not enabled then
        local o = opts or {}
        local key = (o.exact == false and "g" or "") .. (o.backward and "#" or "*")
        local count = vim.v.count > 0 and tostring(vim.v.count) or ""
        -- "n": the mapping this call sits in must not fire again
        vim.api.nvim_feedkeys(count .. key, "n", false)
        return
    end
    search.search_cword(opts)
end

---@class pcre.Opts
---@field substitute_abbrev? boolean|"enter" expand a typed :s (with any range)
---into :S. true rewrites the cmdline visibly the moment the separator is
---typed (and the 'inccommand' preview is the pcre one); "enter" swaps inside
---CmdlineLeave instead, so the cmdline shows the :s you typed all along --
---but while typing, the preview is native :s reading a pcre pattern.

---@param opts? pcre.Opts
function M.setup(opts)
    opts = opts or {}

    if pcre2.err then
        enabled = false
        vim.notify("pcre.nvim: " .. pcre2.err .. "; staying native", vim.log.levels.WARN)
        return
    end

    vim.api.nvim_create_user_command("S", substitute.run, {
        nargs = 1,
        range = true,
        preview = substitute.preview,
        desc = "PCRE2 substitute (libpcre2)",
    })

    vim.api.nvim_create_user_command("Pcre", M.toggle, {
        desc = "toggle pcre off/on (native / and :s while off)",
    })

    local group = vim.api.nvim_create_augroup("pcre", {})

    -- Highlights are painted per window over the visible lines only, so any
    -- scroll, resize, window/buffer switch or edit needs a repaint.
    vim.api.nvim_create_autocmd(
        { "WinScrolled", "WinResized", "BufEnter", "TextChanged", "TextChangedI" },
        { group = group, callback = search.repaint })

    -- :noh must clear our highlights too or the search won't feel native;
    -- CmdlineLeave is the only hook :nohlsearch fires.
    vim.api.nvim_create_autocmd("CmdlineLeave", {
        group = group,
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

    if opts.substitute_abbrev == "enter" then
        local agroup = vim.api.nvim_create_augroup("pcre.abbrev", {})
        -- The authentic flavour: setcmdline() inside CmdlineLeave still
        -- changes what executes (measured), so the swap to :S happens at the
        -- <CR> and is never visible. The : history records the swapped line
        -- (measured), so the typed one is put back once the command has run.
        -- While the :s is being typed, substitute.live_preview renders the
        -- pcre preview without ever touching the buffer.
        -- 'inccommand' parks at CmdlineEnter: once the native preview has
        -- engaged, writing the option raises E474 (measured in a real UI)
        vim.api.nvim_create_autocmd("CmdlineEnter", {
            group = agroup,
            callback = function()
                if enabled and vim.fn.getcmdtype() == ":" then
                    substitute.park_preview()
                end
            end,
        })
        vim.api.nvim_create_autocmd("CmdlineChanged", {
            group = agroup,
            callback = function()
                if not enabled or vim.fn.getcmdtype() ~= ":" then
                    return
                end
                substitute.live_preview(vim.fn.getcmdline())
            end,
        })
        vim.api.nvim_create_autocmd("CmdlineLeave", {
            group = agroup,
            callback = function()
                substitute.live_stop()
                substitute.unpark_preview()
                if not enabled or vim.v.event.cmdtype ~= ":" or vim.v.event.abort then
                    return
                end
                local line = vim.fn.getcmdline()
                -- range chars, lowercase s, a separator, and the rest; native
                -- stays reachable as :su, and a bare :s never matches
                local range, rest = line:match("^(%s*[%d%%,%.%$<>'+%-;]*)s([^%w%s\\\"|].*)$")
                if not range then
                    return
                end
                local swapped = range .. "S" .. rest
                substitute.pending_typed = line
                vim.fn.setcmdline(swapped)
                vim.schedule(function()
                    if vim.fn.histget(":", -1) == swapped then
                        vim.fn.histdel(":", -1)
                        vim.fn.histadd(":", line)
                    end
                end)
            end,
        })
    elseif opts.substitute_abbrev then
        -- Expand a lone, possibly range-prefixed :s into :S so :%s// muscle
        -- memory lands on PCRE2. Not a real abbreviation: those never fire
        -- after a range (":s/" expands, ":%s/" does not -- measured), so the
        -- rewrite happens on CmdlineChanged the moment the separator is typed.
        -- Native :s stays reachable as :su -- letters before the "s" (or none
        -- after it) never match.
        vim.api.nvim_create_autocmd("CmdlineChanged", {
            group = vim.api.nvim_create_augroup("pcre.abbrev", {}),
            callback = function()
                if not enabled or vim.fn.getcmdtype() ~= ":" then
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
