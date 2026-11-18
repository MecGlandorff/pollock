# Pollock roadmap

## Phase 1: Fast, correct move generation

The first milestone is a board that is provably correct and fast enough that it never limits search. Everything later depends on it.

1. **Board and FEN.** Bitboard board representation with a mailbox for piece lookup, full FEN read/write, and Zobrist keys maintained incrementally (including castling rights and en passant file).
2. **Move generation.** Legal move generation using checker and pin masks, with sliding attacks from magic bitboards (or PEXT where available). Handle castling (including Chess960 later), en passant (including the horizontal-pin case) and promotions. Make/undo must restore state exactly, checked against a from-scratch FEN and Zobrist recompute in tests.
3. **Perft correctness.** Run a perft suite built from the EPD files in [ChrisWhittington/Chess-EPDs](https://github.com/ChrisWhittington/Chess-EPDs), the [tricky positions](https://github.com/niklasf/python-chess/blob/master/examples/perft/tricky.perft) and a few others. Include `perft divide` for debugging mismatches against a reference engine.
4. **Speed and `bench`.** Record median nodes per second across three single-thread release runs, noting the CPU and Zig build settings. Add a `bench` command that searches a fixed position set to a fixed depth and prints total nodes and NPS. The node total is the engine's signature: it only changes when search behavior changes, and it lets us compare builds and engines.

## Phase 2: A game on the clock

Get a complete, legal game played through a GUI-less match runner.

1. **UCI.** Support `uci`, `isready`, `position`, `go` (with `wtime`/`btime`/`movetime`/`depth`) and `stop`. Add `Hash` and `Threads` options up front.
2. **Baseline search.** Iterative deepening with alpha-beta (negamax) and a simple material and piece-square evaluation.
3. **Draws and time.** Repetition detection via Zobrist history (treat a single repeat as a draw inside the search, threefold at the root), the fifty-move rule, and basic time management with a safety margin.
4. **First match.** Use [Fastchess](https://github.com/Disservin/fastchess) to play thousands of games from different openings against a fixed opponent at equal clocks, switching colors. All games must finish legally with no time losses. We use `UHO_Lichess_4852_v1.epd` from [Stockfish books](https://github.com/official-stockfish/books) as our opening book.

## Phase 3: Search strength and testing



## Later

Strength gains are only real if measured, so the test setup comes before the tuning.

- **SPRT testing.** Every change is gated by an SPRT in Fastchess against the previous version, using a fixed opening book, fixed hash and equal time control. No change merges on gut feeling.
- **Transposition table.** Zobrist-keyed TT with a replacement scheme, TT cutoffs, TT move first in ordering, and mate-score adjustment on store and probe.
- **Standard search techniques**, each added and tested on its own: principal variation search, aspiration windows, null-move pruning, late move reductions, killer and history heuristics, check extensions, futility and reverse futility pruning, SEE for capture ordering and pruning.
- **Staged move picker** that generates captures, then quiets, lazily, so cutoffs skip work.
- **NNUE.** Our own network with an incrementally updated accumulator, SIMD inference, and a data generation and training pipeline. Evaluate against the hand-crafted baseline by SPRT.
- **Multithreading.** Lazy SMP over a shared TT.
- **Strength tracking.** Maintain an Elo ladder across versions against a pool of reference engines.

The long-term target is full-strength Stockfish at equal thinking time on the same machine, with both engines free to use the available hardware.
