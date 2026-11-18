# Pollock roadmap

## Phase 1 — A game on the clock

I'd like to measure how quickly our own Zig board can generate, make and undo legal moves on the CPU we'll use to play. The first milestone is getting that board through a timed game.

1. Read and write standard FEN. Use one bitboard per color and piece type, and keep all six FEN fields.
2. Make and undo moves, then generate legal moves. Replay lines with castling, en passant and promotions. Compare the positions with an independent rules implementation and recover the original FEN on undo.
3. Measure move generation with `perft`, which counts legal lines to a fixed depth. Kiwipete has 97,862 lines at depth three. Once the counts agree, record median nodes per second across three single-thread release runs with the same positions and depths. Note the CPU and Zig build settings. [Reference positions](https://github.com/niklasf/python-chess/blob/master/examples/perft/tricky.perft)

For the first games, a material evaluator and shallow search behind UCI are enough. Play the same opening twice against a fixed opponent at equal clocks, switching colors. Both games should finish legally within Pollock's allotted time. The match runner can handle draw claims for this pair.

## Later

Add repetition and draw handling to search before measuring playing strength. Then try our own NNUE and search ideas against the timed baseline. The long-term target is full-strength Stockfish at equal thinking time on the same machine, with both engines free to use the available hardware.
