#!/usr/bin/env bash
# Offline checks for pcre.nvim: static analysis + the headless suite.
# Offline; no network, no user config.
#
#   tests/run.sh          both tiers
#   tests/run.sh spec     just the headless suite
#   tests/run.sh check    just lua-language-server
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
what="${1:-all}"
rc=0

if [[ "$what" == "all" || "$what" == "check" ]]; then
    if command -v lua-language-server >/dev/null 2>&1; then
        echo "== lua-language-server --check"
        # --check wants the workspace root so it picks up .luarc.json (which
        # declares `vim`)
        out="$(cd "$repo" && timeout 300 lua-language-server --check "$repo" \
            --checklevel=Warning 2>&1)"
        if grep -q "no problems found" <<<"$out"; then
            echo "  ok    no problems"
        else
            echo "$out" | sed -e 's/^/  /'
            rc=1
        fi
    else
        echo "== lua-language-server not installed -- skipping static check"
    fi
fi

if [[ "$what" == "all" || "$what" == "spec" ]]; then
    echo "== headless suite"
    # timeout: the prompt-loop tests read from typeahead; a bug that leaves
    # getcharstr() waiting would otherwise hang forever.
    # one nvim per spec: the last-pattern state is process-global
    # -l, not -c "luafile": measured, under luafile a Vim error raised inside
    # vim.fn.* (E348 from expand("<cword>") on a blank line, say) does not
    # surface as a Lua error -- the call just returns "" and the suite cannot
    # see it. Under -l it propagates and the test fails. The sibling repos in
    # this stack all use -l for the same reason.
    for spec in "$repo"/tests/spec*.lua; do
        timeout 60 nvim --headless --clean \
            --cmd "set rtp+=$repo" \
            -l "$spec" 2>&1 || rc=1
    done
fi

exit $rc
