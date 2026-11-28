# Pollock

Pollock is a single-threaded Zig chess engine for standard-chess UCI GUIs. This snapshot uses Pieter te Brake's legal move generator and the Wide1024 network trained on 661,684,245 positions.

## Build and play

Use Zig 0.17.1.

```powershell
zig build -Doptimize=ReleaseFast -j1
.\zig-out\bin\pollock.exe uci --weights .\played\wide1024-661m.pnn
```

In a chess GUI, add `zig-out\bin\pollock.exe` as a UCI engine and set `EvalFile` to the absolute path of `played\wide1024-661m.pnn`. Use standard chess and turn off pondering.

The Windows bundle contains the exact native executable used for the games. After extracting it, run `.\pollock.exe uci --weights .\played\wide1024-661m.pnn`. This build uses AVX2, BMI1, BMI2, F16C, LZCNT and POPCNT. Build from source for a different CPU target.

## UCI support

Use `go depth`, `go nodes`, `go movetime`, or standard game clocks with `wtime`, `btime`, `winc`, `binc`, and optional `movestogo`. Use `go infinite` followed by `stop` for analysis. Put `searchmoves` last when restricting root moves. A pending re-search can put the reported node count slightly over its limit. For mate analysis, use a time or depth limit.

## Checks

```powershell
zig build test -Doptimize=ReleaseSafe -j1
python tests/verify_arena.py
```

## Games

This release archives 144 Fastchess games against nine opponents from the original gauntlet. Each matchup uses eight openings with both colors, 15 seconds plus 0.15 seconds per move, one thread, and 64 MiB hash where supported.

Parentheses show the CCRL Blitz anchor ratings from 2026-11-21.

| Opponent | W–D–L | Points |
| --- | ---: | ---: |
| Vajolet2 3.2 (3400) | 8–7–1 | 11.5/16 |
| Stockfish 10 (3511) | 1–8–7 | 5/16 |
| Ethereal 12.50 (3395) | 6–8–2 | 10/16 |
| Xiphos 0.6 (3354) | 10–6–0 | 13/16 |
| Laser 1.7 (3292) | 8–5–3 | 10.5/16 |
| Fire 8.2 (3481) | 3–10–3 | 8/16 |
| Berserk 5.0 (3452) | 8–6–2 | 11/16 |
| Weiss 2.0 (3318) | 7–8–1 | 11/16 |
| Defenchess 2.2 (3280) | 10–5–1 | 12.5/16 |
| **Total** | **61–63–20** | **92.5/144** |

The fitted local blitz estimate for this subset is **3493.6 Elo** (paired 95% interval **3458.7–3530.4**). The subset was selected for this release after play began. The interval treats the CCRL anchors as fixed.

[Played games and benchmark metadata](arena_archive_played_games/games.json)
