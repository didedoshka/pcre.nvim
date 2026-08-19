#!/usr/bin/env bash
# PostToolUse hook: after any Lua edit in this repo, run tests/run.sh and
# hand failures straight back on exit 2, so a break surfaces at the edit that
# caused it rather than three edits later.
#
# It runs the *whole* suite, not just the linter, because the two tiers catch
# disjoint things: lua-language-server finds syntax errors and undefined
# globals but not cross-module breakage; the headless suite actually loads the
# modules and drives them, so it does.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

file="$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"
[[ "$file" == *.lua ]] || exit 0        # not lua -- nothing to do
[[ "$file" == "$repo"/* ]] || exit 0    # not this repo's lua

out="$("$repo/tests/run.sh" 2>&1)" && exit 0

{
    echo "tests/run.sh failed (baseline for this repo is green):"
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r/\n/g' <<<"$out" \
        | grep -vE '^\s*$|^\s*Initializing|^\s*[>=]+ *[0-9]+/[0-9]+'
} >&2
exit 2
