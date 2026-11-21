"""Play one legal game between Pollock's one-ply NNUE and a material evaluator."""
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import chess
import chess.pgn

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_EXE = ROOT / "zig-out" / "bin" / ("pollock.exe" if os.name == "nt" else "pollock")
PIECE_CP = (0, 100, 320, 330, 500, 900, 0)


def material_cp(board):
    white = sum(PIECE_CP[p] * (len(board.pieces(p, chess.WHITE)) - len(board.pieces(p, chess.BLACK)))
                for p in chess.PIECE_TYPES)
    return white if board.turn == chess.WHITE else -white


def zig_scores(exe, weights, fens, *, parent=None):
    scores = []
    prefix = [parent] if parent is not None else []
    for start in range(0, len(fens), 32):
        batch = fens[start:start + 32]
        run = subprocess.run([exe, "eval", "--weights", weights, *prefix, *batch], capture_output=True, text=True)
        if run.returncode:
            raise RuntimeError(run.stderr.strip() or f"Pollock exited with {run.returncode}")
        values = [int(line) for line in run.stdout.splitlines()]
        if len(values) != len(prefix) + len(batch):
            raise ValueError("Expected one Pollock score per FEN")
        scores.extend(values[len(prefix):])
    return scores


def choose_move(board, evaluate):
    """Maximize the mover's score. UCI spelling breaks ties reproducibly."""
    moves = sorted(board.legal_moves, key=chess.Move.uci)
    if not moves:
        raise ValueError("No legal move in this position")
    scores = [0] * len(moves)
    pending, fens = [], []
    for i, move in enumerate(moves):
        board.push(move)
        try:
            outcome = board.outcome()
            if outcome is None:
                pending.append(i)
                fens.append(board.fen(en_passant="fen"))
            elif outcome.winner is not None:
                scores[i] = float("inf")  # Checkmate delivered by the mover.
        finally:
            board.pop()
    for i, child_score in zip(pending, evaluate(fens), strict=True):
        scores[i] = -child_score  # The opponent is to move in the child position.
    return moves[max(range(len(moves)), key=scores.__getitem__)]


def digest(path):
    sha = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


@contextmanager
def recorded_run(out, exe, inputs, settings):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=ROOT, text=True).rstrip()

    report = dict(started_utc=datetime.now(timezone.utc).isoformat(), state="started",
                  revision=git("rev-parse", "HEAD"), changes=git("status", "--porcelain"),
                  command=[sys.executable, *sys.argv], python=platform.python_version(),
                  chess=chess.__version__, pollock_sha256=digest(exe),
                  inputs={str(p.resolve()): digest(p) for p in inputs}, **settings)
    patch = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=ROOT)
    out.mkdir(parents=True, exist_ok=False)
    if patch:
        (out / "source.patch").write_bytes(patch)

    def save():
        tmp = out / "run.tmp"
        tmp.write_text(json.dumps(report, indent=2) + "\n")
        tmp.replace(out / "run.json")

    save()
    try:
        yield report
    except BaseException as error:
        report.update(state="failed", error=str(error))
        raise
    else:
        report["state"] = "complete"
    finally:
        save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, default=ROOT / "runs/v0/network.json")
    parser.add_argument("--pollock", type=Path, default=DEFAULT_EXE)
    parser.add_argument("--color", choices=("white", "black"), default="white", help="NNUE color")
    parser.add_argument("--fen", default=chess.STARTING_FEN)
    parser.add_argument("--out", required=True, type=Path, help="new directory for the PGN and run record")
    args = parser.parse_args()
    board = chess.Board(args.fen)
    if not board.is_valid():
        parser.error("Invalid starting position")
    nnue_color = args.color == "white"
    exe = args.pollock.resolve()

    def network(fens):
        return zig_scores(exe, args.weights, fens, parent=board.fen(en_passant="fen"))

    def material(fens):
        return [material_cp(chess.Board(fen)) for fen in fens]

    with recorded_run(args.out, exe, [args.weights], dict(seed=None, nnue_color=args.color, fen=args.fen)) as report:
        while (outcome := board.outcome()) is None:
            board.push(choose_move(board, network if board.turn == nnue_color else material))
        game = chess.pgn.Game.from_board(board)
        game.headers.update(Event="Pollock NNUE v0 arena", Date=datetime.now(timezone.utc).strftime("%Y.%m.%d"),
                            White="NNUE" if nnue_color else "Material", Black="Material" if nnue_color else "NNUE",
                            Result=outcome.result())
        (args.out / "game.pgn").write_text(str(game) + "\n\n")
        report.update(result=outcome.result(), termination=outcome.termination.name,
                      plies=len(board.move_stack), final_fen=board.fen())
        print(f"{outcome.result()}  {outcome.termination.name}  {len(board.move_stack)} plies")


if __name__ == "__main__":
    main()
