# Pollock

## First Trial NNUE with basic negamax/PVS search

Pollock is a standard chess engine written in Zig. Its iterative-deepening negamax search uses principal variation search (PVS), quiescence search and a transposition table. Its 128-unit NNUE updates both kings’ perspectives as pieces move and selects one of eight output heads by piece count.

The trial network trained on 24 million positions. Its targets combine 90% Stockfish 18 static evaluation and 10% recorded Lichess game outcome. Pollock searches with its own code and evaluates positions with its exported weights.

## Build and run

Build the engine and run its tests with Zig 0.17.1.

```powershell
zig build -Doptimize=ReleaseFast -Dcpu=native
zig build test -Doptimize=ReleaseSafe
uv run --locked --project research/nnue_v0 python -m unittest discover -s research/nnue_v0
.\zig-out\bin\pollock.exe perft 5
```

Starting-position perft at depth 5 should return 4,865,609. A UCI GUI can launch the executable directly and set `EvalFile` to a network. To play with the trial weights, supply the exported `network.pnn` file from the 24M run.

```powershell
.\zig-out\bin\pollock.exe uci --weights runs/static-wide128-24m/network.pnn
```

The trial weights are a separate run artifact. The original trainer produces `runs/v0/network.json`, which the engine also accepts. The `eval --weights` command evaluates one or more quoted FENs for the side to move. [Train the original evaluator and play a game](research/nnue_v0/README.md)

## Match results

These matches used the binaries identified below. Both Stockfish 18 matches used `UCI_LimitStrength=true` and `UCI_Elo=3000` at 120 seconds plus one second per move. Each opening was scheduled once with each color, with one search thread and 16 MiB of hash per engine. [Stockfish UCI options](https://github.com/official-stockfish/Stockfish/wiki/UCI-Protocol-and-Stockfish-Commands#uci_elo)

| Pollock entry | Opponent | Clock | Wins–draws–losses | Points | Match status | Match performance |
| --- | --- | --- | ---: | ---: | --- | ---: |
| First Trial, 24M weights | Stockfish 18 at UCI Elo 3000 | 120+1 | 9–5–2 | 11.5/16 (71.9%) | Paused at 16 of 24 | 3163 provisional |
| Earlier build, 8M weights | Stockfish 18 at UCI Elo 3000 | 120+1 | 13–13–6 | 19.5/32 (60.9%) | Complete, 32 games | 3077 |
| First Trial, 24M weights | Same executable, 8M weights | 10+0.1 | 16–26–6 | 29/48 (60.4%) | Complete, 48 games | +73 vs. 8M |

For a score fraction `s`, the performance difference is `400 × log10(s / (1 − s))`. The two Stockfish rows use the opponent’s 3000 setting as the reference. The 24M match covered eight complete opening pairs before it paused. Its estimate applies to that matchup. The earlier 8M build led 12–8 after 20 games and finished 19½–12½. The completed 48-game match measures the weight change on the same executable at the shorter clock.

<details>
<summary>Benchmark files and versions</summary>

The table uses the first 12 hexadecimal digits of each file’s SHA-256. The opening line is one-based. Both Stockfish matches used the same Stockfish 18 AVX2 executable (`c86215fa1977`).

| Match log directory | Pollock executable | Pollock weights | Opening file | First line |
| --- | --- | --- | --- | ---: |
| `match-wide24m-sf3000` | `603871d4ba05` | `9d061dacddee` | `e8b41263f4f2` | 65 |
| `match-wide128-sf3000` | `58e92c008211` | `3f2dbecea954` | `cc98a5cc352e` | 89 |
| `match-wide24m-vs-wide8m` | `603871d4ba05` | `9d061dacddee` | `e8b41263f4f2` | 41 |

The trial `network.pnn` has SHA-256 `9d061dacddee553a5813016fff1c736c8f91fa0319428213c227119a7b5fc53d`. The 24M trial executable was built from source snapshot `0ea59ae2437b`, before the public NNUE and UCI fixes in this revision. Each local `runs/<match log directory>/match.json` records the full file hashes, opening schedule and individual PGN filenames.

</details>
