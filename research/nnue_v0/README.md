# NNUE v0

Can Pollock train a small material evaluator, read its exported weights in Zig, and use them to finish a legal game? This experiment uses 768 piece-square inputs, 16 clipped hidden units, and one score in centipawns. [Stockfish’s piece-square feature example](https://official-stockfish.github.io/docs/nnue-pytorch-wiki/docs/nnue.html#a-simple-input-feature-set)

## Main finding from this experiment

On **1,350 held-out positions**, the exported network’s mean absolute error against exact material balance was **40.3 centipawns**. Given the same quantized weights, the Python reference and Zig returned identical integer scores on every position. Future experiments can compare new models against this material error and reuse the v0 weights to check changes to the Zig evaluator.

The run used seed 7 and 40 epochs at commit `3a7089c`. The training command below writes the results to `runs/v0/run.json`.

## Run from the repository root

Use Zig 0.17.1 and uv. The Python project and its lockfile live in `research/nnue_v0/`.

```sh
zig build -Doptimize=ReleaseSafe
uv sync --locked --project research/nnue_v0
uv run --locked --project research/nnue_v0 research/nnue_v0/train_nnue.py --out runs/v0
./zig-out/bin/pollock eval '7k/p7/8/8/8/2q5/P7/1N5K w - - 0 1'
uv run --locked --project research/nnue_v0 research/nnue_v0/arena.py --out runs/game-v0
```

`pollock eval` returns one integer per FEN from the side to move’s perspective. It loads `runs/v0/network.json` by default. Use `eval --weights FILE FEN [FEN ...]` to select a different export. In a batch, Zig builds the first position’s accumulator and applies piece-square changes from that position to each subsequent one.

The trainer saves `checkpoint.pt`, the exported `network.json`, and `run.json`. The arena saves `game.pgn` and its own `run.json`. Each invocation needs a fresh output directory. The run records include the revision, local changes, command, inputs, and training seed where applicable.

## What the experiment measures

The trainer takes board layouts from `tests/perft/marcel.epd`. Its target is material balance using 100 centipawns for a pawn, 320 for a knight, 330 for a bishop, 500 for a rook, and 900 for a queen. It holds out one fifth of layout groups and keeps color-mirrored positions in the same group.

Compare held-out mean absolute error against the untrained network. Before using the export for play, the trainer checks every held-out integer score against Zig. A mismatch identifies a position to debug.

Both players search one ply. The NNUE plays White by default, and its opponent scores material directly. Python-chess supplies legal moves and automatic game endings. Checkmate wins immediately, a draw scores zero, and ties follow UCI move order. Use `--color black` to swap sides. A completed game checks the full pipeline. Measuring playing strength takes a match across openings and colors.

## Checks

```sh
zig build test
uv run --locked --project research/nnue_v0 python -m unittest discover -s research/nnue_v0
```

With fixed material weights, the player must take the undefended queen on c3 with the b1 knight. The Zig test checks that the capture’s incremental accumulator equals a fresh calculation and that undo restores every lane.
