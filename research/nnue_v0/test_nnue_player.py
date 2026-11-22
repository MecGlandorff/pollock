import json
import tempfile
import unittest
from pathlib import Path

import chess

from arena import DEFAULT_EXE, choose_move, zig_scores


class PlayerTest(unittest.TestCase):
    def test_white_takes_the_undefended_queen(self):
        # One lane per piece plane counts pieces. Each contribution is 16/256 of its output weight.
        values = [100, 320, 330, 500, 900, 0, -100, -320, -330, -500, -900, 0]
        rows = [[0] * 16 for _ in range(768)]
        for row_index, row in enumerate(rows):
            row[row_index // 64] = 16
        net = dict(version=1, feature_weights=rows, hidden_bias=[0] * 16,
                   output_weights=[v * 16 for v in values] + [0] * 4, output_bias=0)
        board = chess.Board("7k/p7/8/8/8/2q5/P7/1N5K w - - 0 1")
        with tempfile.TemporaryDirectory() as directory:
            weights = Path(directory) / "material.json"
            weights.write_text(json.dumps(net))
            parent = board.fen()
            move = choose_move(board, lambda fens: zig_scores(DEFAULT_EXE, weights, fens, parent=parent))
            self.assertEqual(move.uci(), "b1c3")
            self.assertEqual(board.fen(), parent)
            board.push(move)
            self.assertEqual(zig_scores(DEFAULT_EXE, weights, [parent, board.fen()]), [-580, -320])
