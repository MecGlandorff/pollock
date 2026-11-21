import json
import tempfile
import unittest
from pathlib import Path

import chess

from arena import DEFAULT_EXE, zig_scores
from games import split_games


class GameOutcomeTest(unittest.TestCase):
    def test_results_follow_the_side_to_move_and_games_stay_in_one_split(self):
        # Each game has one interior position, so the label has a known perspective.
        games = [
            '[Result "1-0"]\n\n1. e4 e5 1-0',
            '[Result "0-1"]\n\n1. d4 d5 0-1',
            '[Result "1/2-1/2"]\n\n1. c4 c5 1/2-1/2',
            '[SetUp "1"]\n[FEN "7k/7p/8/8/8/8/P7/K7 b - - 0 1"]\n[Result "1-0"]\n\n1... h6 2. a3 1-0',
            '[Event "Annotated copy"]\n[Result "1-0"]\n\n1. e4 {[%eval 9.00]} e5 1-0',
            '[Result "*"]\n\n1. Nf3 d5 *',
            '[WhiteTitle "BOT"]\n[Result "1-0"]\n\n1. h4 h5 1-0',
        ]
        with tempfile.TemporaryDirectory() as directory:
            pgn = Path(directory) / "games.pgn"
            pgn.write_text("\n\n".join(games), encoding="utf-8")
            train, valid, counts = split_games(pgn, 100)
            self.assertEqual(counts, dict(train=3, holdout=1, skipped=2, duplicates=1))
            pgn.write_text("\n\n".join(reversed(games)), encoding="utf-8")
            self.assertEqual(split_games(pgn, 100)[:2], (train, valid))

        samples = train + valid
        self.assertEqual([(b.piece_at(chess.H6), label) for b, label in samples if b.turn == chess.WHITE],
                         [(chess.Piece(chess.PAWN, chess.BLACK), 1)])
        for square, expected in ((chess.E4, -1), (chess.D4, 1), (chess.C4, 0)):
            self.assertEqual([label for b, label in samples if b.turn == chess.BLACK and b.piece_at(square)], [expected])

    def test_games_with_identical_moves_and_different_results_stay_together(self):
        games = ['[Result "1-0"]\n\n1. e4 e5 1-0', '[Result "0-1"]\n\n1. e4 e5 0-1',
                 '[Result "1/2-1/2"]\n\n1. c4 c5 1/2-1/2']
        with tempfile.TemporaryDirectory() as directory:
            pgn = Path(directory) / "games.pgn"
            pgn.write_text("\n\n".join(games), encoding="utf-8")
            train, valid, counts = split_games(pgn, 10)
            self.assertEqual(counts["duplicates"], 0)
            self.assertEqual(sorted(sorted(label for _, label in s) for s in (train, valid)), [[-1, 1], [0]])
            pgn.write_text("\n\n".join(reversed(games)), encoding="utf-8")
            self.assertEqual(split_games(pgn, 10)[:2], (train, valid))

    def test_zig_scores_signed_outcomes_in_thousandths_and_preserves_material_units(self):
        net = dict(version=1, feature_weights=[[0] * 16 for _ in range(768)], hidden_bias=[0] * 16,
                   output_weights=[0] * 16, output_bias=1400)
        fens = [chess.STARTING_FEN, chess.STARTING_FEN.replace(" w ", " b ")]
        with tempfile.TemporaryDirectory() as directory:
            weights = Path(directory) / "network.json"
            weights.write_text(json.dumps(net))
            self.assertEqual(zig_scores(DEFAULT_EXE, weights, fens), [1400, -1400])
            net["score_unit"] = "outcome_per_mille"
            weights.write_text(json.dumps(net))
            self.assertEqual(zig_scores(DEFAULT_EXE, weights, fens), [1000, -1000])
