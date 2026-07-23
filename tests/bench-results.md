# Benchmark results

Point-in-time runs of `tests/bench.lua` on the dev box, kept so backend changes
have a before/after. Median of 25, same corpus and patterns in both runs.

## 2026-07-23 — libpcre2 over LuaJIT FFI (commit 0013a02)

```
pcre.nvim find-all benchmark  (nvim 0.13.0-dev+ga59c8a9c76, libpcre2 FFI, median of 25)
case / lines            matches    pcre ms  native ms        x
--------------------------------------------------------------
literal 'request' / 100       14       0.02       0.02       1x
literal 'request' / 1000      142       0.11       0.16       1x
literal 'request' / 10000     1428       0.97       1.62       1x
literal 'request' / 50000     7142       5.10       8.21       1x
word \w+ / 100              460       0.07       0.53       0x
word \w+ / 1000            4571       0.93       5.26       0x
word \w+ / 10000          45717      10.67      72.70       0x
word \w+ / 50000         228571      65.19     411.02       0x
TODO w/ lookahead / 100       14       0.01       0.02       1x
TODO w/ lookahead / 1000      143       0.08       0.17       1x
TODO w/ lookahead / 10000     1429       0.87       1.72       1x
TODO w/ lookahead / 50000     7143       4.95       9.18       1x
--------------------------------------------------------------
per-call floor (1 line, 0 matches): 0.00 ms -- paid per keystroke
```

Faster than the native engine in every cell (the x column rounds; e.g. \w+ /
50000 is 0.16x).

## 2026-07-22 — rg subprocess (the backend this replaced)

```
pcre.nvim find-all benchmark  (nvim 0.13.0-dev+ga59c8a9c76, rg ripgrep 15.1.0 (rev af60c2de9d), median of 25)
case / lines            matches    pcre ms  native ms        x
--------------------------------------------------------------
literal 'request' / 100       14       2.25       0.02     105x
literal 'request' / 1000      142       3.05       0.17      18x
literal 'request' / 10000     1428      11.94       1.59       8x
literal 'request' / 50000     7142      59.45       8.15       7x
word \w+ / 100              460       3.58       0.48       7x
word \w+ / 1000            4571      12.55       5.11       2x
word \w+ / 10000          45717     173.58      70.33       2x
word \w+ / 50000         228571     925.43     350.41       3x
TODO w/ lookahead / 100       14       8.44       0.03     265x
TODO w/ lookahead / 1000      143       9.59       0.19      51x
TODO w/ lookahead / 10000     1429      16.19       1.79       9x
TODO w/ lookahead / 50000     7143      54.34       9.28       6x
--------------------------------------------------------------
rg spawn floor (1 line, 0 matches): 5.45 ms -- paid per keystroke
```
