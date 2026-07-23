-- In-process PCRE2 via LuaJIT FFI -- the engine behind find and :S expansion.
-- This is the same library rg embedded for --pcre2, bound directly so a
-- keystroke costs a match call, not a process spawn (measured: ~5 ms/spawn).
-- Loading can fail (PUC-Lua build, no libpcre2 on the box): then M.err is set
-- and find() reports it; setup() turns the plugin off with a notify.
local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
    M.err = "LuaJIT ffi not available (PUC-Lua build of nvim?)"
    return M
end
local bit = require("bit")

-- Declared as char*, not PCRE2's uint8_t*: the ABI is identical and LuaJIT
-- only auto-converts Lua strings to char pointers.
ffi.cdef([[
typedef struct pcre2_real_code_8 pcre2_code_8;
typedef struct pcre2_real_match_data_8 pcre2_match_data_8;
typedef struct pcre2_real_match_context_8 pcre2_match_context_8;
typedef struct pcre2_real_general_context_8 pcre2_general_context_8;
typedef struct pcre2_real_compile_context_8 pcre2_compile_context_8;

pcre2_code_8 *pcre2_compile_8(const char *pattern, size_t length, uint32_t options,
    int *errorcode, size_t *erroroffset, pcre2_compile_context_8 *ccontext);
void pcre2_code_free_8(pcre2_code_8 *code);
int pcre2_jit_compile_8(pcre2_code_8 *code, uint32_t options);
int pcre2_match_8(const pcre2_code_8 *code, const char *subject, size_t length,
    size_t startoffset, uint32_t options, pcre2_match_data_8 *match_data,
    pcre2_match_context_8 *mcontext);
pcre2_match_data_8 *pcre2_match_data_create_from_pattern_8(const pcre2_code_8 *code,
    pcre2_general_context_8 *gcontext);
void pcre2_match_data_free_8(pcre2_match_data_8 *match_data);
size_t *pcre2_get_ovector_pointer_8(pcre2_match_data_8 *match_data);
int pcre2_get_error_message_8(int errorcode, char *buffer, size_t bufflen);
pcre2_match_context_8 *pcre2_match_context_create_8(pcre2_general_context_8 *gcontext);
void pcre2_match_context_free_8(pcre2_match_context_8 *mcontext);
int pcre2_set_match_limit_8(pcre2_match_context_8 *mcontext, uint32_t value);
int pcre2_set_depth_limit_8(pcre2_match_context_8 *mcontext, uint32_t value);
int pcre2_substitute_8(const pcre2_code_8 *code, const char *subject, size_t length,
    size_t startoffset, uint32_t options, pcre2_match_data_8 *match_data,
    pcre2_match_context_8 *mcontext, const char *replacement, size_t rlength,
    char *outputbuffer, size_t *outlengthptr);
]])

local lib
-- Full sonames, not "pcre2-8": Linux ships only the versioned .so.0 (no -dev
-- symlink), and on arm64 macs /opt/homebrew/lib is not in dlopen's default path.
for _, name in ipairs({
    "libpcre2-8.so.0",
    "pcre2-8",
    "/opt/homebrew/lib/libpcre2-8.dylib",
    "/usr/local/lib/libpcre2-8.dylib",
    "libpcre2-8.dylib",
}) do
    local ok, l = pcall(ffi.load, name)
    if ok then
        lib = l
        break
    end
end
if not lib then
    M.err = "libpcre2-8 not found (Linux: distro package; macOS: brew install pcre2)"
    return M
end

-- From pcre2.h; no header on typical boxes, so verified behaviorally by the suite.
local UTF = 0x00080000              -- compile: pattern and subject are UTF-8
local UCP = 0x00020000              -- compile: \w, \b & co are unicode-aware (rg's choice too)
local MATCH_INVALID_UTF = 0x04000000 -- compile: don't blow up on broken bytes in the buffer
local CASELESS = 0x00000008         -- compile: the :S /i flag
local JIT_COMPLETE = 0x00000001
local NOTEMPTY_ATSTART = 0x00000008 -- match: forbid an empty match at the start offset
local ANCHORED = 0x80000000         -- match: no advancing while retrying after an empty match
local ERR_NOMATCH = -1
local ERR_NOMEMORY = -48
-- runaway backtracking cut off by the limits below; also its JIT-stack variant
local ERR_MATCHLIMIT, ERR_DEPTHLIMIT, ERR_JIT_STACKLIMIT = -47, -53, -46
local SUBST = bit.bor(
    0x00001000, -- OVERFLOW_LENGTH: report the needed buffer size instead of failing
    0x00000400, -- UNSET_EMPTY: $2 of an unmatched branch expands to "", like rg -r
    0x00000800, -- UNKNOWN_UNSET: $9 with two groups is "" too, not an error
    0x00010000, -- MATCHED: expand against the match already in match_data, don't re-match
    0x00020000  -- REPLACEMENT_ONLY: output just the expansion, not the whole subject
)

-- Half-typed patterns are the normal input here, and this runs in-process: the
-- limits keep a backtracking bomb at "no matches yet" instead of a frozen nvim.
local mctx = ffi.gc(lib.pcre2_match_context_create_8(nil), lib.pcre2_match_context_free_8)
lib.pcre2_set_match_limit_8(mctx, 1000000)
lib.pcre2_set_depth_limit_8(mctx, 10000)

local errbuf = ffi.new("char[256]")
local function errmsg(rc)
    lib.pcre2_get_error_message_8(rc, errbuf, 256)
    return "PCRE2: " .. ffi.string(errbuf)
end

-- One-slot cache: n/N and a repaint re-use the accepted pattern; while typing
-- every pattern is new anyway. Old codes are freed by the ffi.gc hook.
local cache = {} ---@type { pattern: string?, caseless: boolean?, code: ffi.cdata*? }

local function compile(pattern, caseless)
    caseless = caseless or false
    if cache.code and cache.pattern == pattern and cache.caseless == caseless then
        return cache.code
    end
    local errcode = ffi.new("int[1]")
    local erroff = ffi.new("size_t[1]")
    local opts = bit.bor(UTF, UCP, MATCH_INVALID_UTF, caseless and CASELESS or 0)
    local code = lib.pcre2_compile_8(pattern, #pattern, opts, errcode, erroff, nil)
    if code == nil then
        return nil, ("%s (at pattern offset %d)"):format(errmsg(errcode[0]), tonumber(erroff[0]))
    end
    ffi.gc(code, lib.pcre2_code_free_8)
    lib.pcre2_jit_compile_8(code, JIT_COMPLETE) -- best effort; interpreter otherwise
    cache.pattern, cache.caseless, cache.code = pattern, caseless, code
    return code
end

local outcap = 256
local outbuf = ffi.new("char[?]", outcap)
local outlen = ffi.new("size_t[1]")

---Expand repl against the match currently held in md (subject = line).
---@return string? text, string? err
local function expand(code, line, md, repl)
    while true do
        outlen[0] = outcap
        local rc = lib.pcre2_substitute_8(code, line, #line, 0, SUBST, md, mctx,
            repl, #repl, outbuf, outlen)
        if rc >= 0 then
            return ffi.string(outbuf, tonumber(outlen[0]))
        elseif rc == ERR_NOMEMORY then
            outcap = math.max(outcap * 2, tonumber(outlen[0]) + 1)
            outbuf = ffi.new("char[?]", outcap)
        else
            return nil, errmsg(rc)
        end
    end
end

---@class pcre2.Match
---@field lnum integer 1-based line (index into `lines`)
---@field scol integer 0-based start byte column
---@field ecol integer 0-based end byte column, exclusive
---@field text string? repl expansion, when opts.repl given

---All matches of pattern over lines, in order. Lines are matched one by one
---(patterns never cross a newline, like rg without -U).
---@param lines string[]
---@param pattern string
---@param opts? { caseless?: boolean, repl?: string }
---@return pcre2.Match[]? matches, string? err
function M.find(lines, pattern, opts)
    opts = opts or {}
    local code, cerr = compile(pattern, opts.caseless)
    if not code then
        return nil, cerr
    end
    local md = ffi.gc(lib.pcre2_match_data_create_from_pattern_8(code, nil),
        lib.pcre2_match_data_free_8)
    local ov = lib.pcre2_get_ovector_pointer_8(md)
    local matches = {}
    for lnum, line in ipairs(lines) do
        local len = #line
        local off, mopts = 0, 0
        while off <= len do
            local rc = lib.pcre2_match_8(code, line, len, off, mopts, md, mctx)
            if rc == ERR_NOMATCH then
                if mopts == 0 then
                    break
                end
                -- the anchored retry after an empty match found nothing here:
                -- advance one code point (skip UTF-8 continuation bytes) and go on
                off = off + 1
                while off < len and bit.band(line:byte(off + 1), 0xC0) == 0x80 do
                    off = off + 1
                end
                mopts = 0
            elseif rc < 0 then
                if rc == ERR_MATCHLIMIT or rc == ERR_DEPTHLIMIT or rc == ERR_JIT_STACKLIMIT then
                    break -- pathological mid-typing pattern: this line just has no more matches
                end
                return nil, errmsg(rc)
            else
                local s, e = tonumber(ov[0]), tonumber(ov[1])
                ---@cast s integer
                ---@cast e integer
                local m = { lnum = lnum, scol = s, ecol = e }
                if opts.repl then
                    local text, xerr = expand(code, line, md, opts.repl)
                    if not text then
                        return nil, xerr
                    end
                    m.text = text
                end
                matches[#matches + 1] = m
                if e == s then
                    -- empty match: retry at the same spot requiring substance,
                    -- the NOMATCH branch above then advances past it
                    off, mopts = s, bit.bor(NOTEMPTY_ATSTART, ANCHORED)
                else
                    off, mopts = e, 0
                end
            end
        end
    end
    return matches
end

return M
