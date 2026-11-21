"""Select one position per completed standard game for outcome training."""
import hashlib

import chess
import chess.pgn


WHITE_RESULT = {"1-0": 1, "0-1": -1, "1/2-1/2": 0}


def split_games(path, max_games):
    samples = {}
    skipped = duplicates = 0
    with path.open(encoding="utf-8-sig") as stream:
        while len(samples) < max_games:
            game = chess.pgn.read_game(stream)
            if game is None:
                break
            result = WHITE_RESULT.get(game.headers.get("Result"))
            if result is None or game.errors or "BOT" in (
                game.headers.get("WhiteTitle"), game.headers.get("BlackTitle")
            ):
                skipped += 1
                continue
            board = game.board()
            moves = list(game.mainline_moves())
            if (type(board) is not chess.Board or board.chess960
                    or not board.is_valid() or len(moves) < 2):
                skipped += 1
                continue

            # Copies with different annotations count once. Identical play can have
            # distinct results (for example timeouts), which belong in the same split.
            mainline = " ".join(move.uci() for move in moves)
            key = hashlib.sha256(f"{board.fen()} {mainline}".encode()).digest()
            if (key, result) in samples:
                duplicates += 1
                continue
            # Pick an interior ply independently of the result and training seed.
            ply = 1 + int.from_bytes(key[8:16], "big") % (len(moves) - 1)
            for move in moves[:ply]:
                board.push(move)
            if board.is_game_over():
                skipped += 1
                continue
            samples[key, result] = (board.copy(stack=False), result if board.turn == chess.WHITE else -result)

    mainlines = sorted({key for key, _ in samples})
    if len(mainlines) < 2:
        raise ValueError("Outcome training needs two distinct completed standard mainlines with an interior position")
    holdout = set(mainlines[:max(1, len(mainlines) // 5)])
    train, valid = [], []
    for (key, _), sample in sorted(samples.items()):
        (valid if key in holdout else train).append(sample)
    return train, valid, dict(train=len(train), holdout=len(valid), skipped=skipped, duplicates=duplicates)
