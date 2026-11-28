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
```
