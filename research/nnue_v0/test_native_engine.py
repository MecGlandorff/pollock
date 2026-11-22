import json
import queue
import struct
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from time import monotonic

import chess

from arena import DEFAULT_EXE, zig_scores


class NativeEvaluationTest(unittest.TestCase):
    def test_loaded_networks_score_both_turns_and_an_updated_position(self):
        queen = "7k/8/8/8/8/8/4Q3/4K3 w - - 0 1"
        kings = "7k/8/8/8/8/8/8/4K3 b - - 0 1"
        fens = [queen, queen.replace(" w ", " b "), kings]
        with tempfile.TemporaryDirectory() as directory:
            # Zero feature weights leave only the material term and side-to-move bias.
            king = Path(directory) / "king.json"
            king.write_text(json.dumps(dict(version=2, score_unit="centipawns",
                                            feature_weights=[[[0] * 32] * 768] * 8,
                                            hidden_bias=[0] * 32, output_weights=[[0] * 32] * 3,
                                            tempo=[13] * 3)), encoding="utf-8")
            wide = Path(directory) / "wide.pnn"
            header = struct.pack("<8s4H", b"PLKNNUE3", 8, 768, 128, 8)
            weights = bytes(2 * (8 * 768 * 128 + 128 + 8 * 2 * 128))
            wide.write_bytes(header + weights + struct.pack("<8i", *([11] * 8)))
            for path, bias in [(king, 13), (wide, 11)]:
                with self.subTest(network=path.name):
                    self.assertEqual(zig_scores(DEFAULT_EXE, path, fens),
                                     [900 + bias, -900 + bias, bias])


class UciSearchTest(unittest.TestCase):
    def setUp(self):
        self.engine = subprocess.Popen([DEFAULT_EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, encoding="utf-8")
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self.read_output, daemon=True)
        self.reader.start()
        self.addCleanup(self.close_engine)

    def read_output(self):
        for line in self.engine.stdout:
            self.lines.put(line.strip())
        self.lines.put(None)

    def close_engine(self):
        if self.engine.poll() is None:
            try:
                self.send("quit")
                self.engine.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.engine.kill()
                self.engine.wait(timeout=5)
        self.engine.stdin.close()
        self.reader.join(timeout=5)
        self.engine.stdout.close()

    def send(self, command):
        self.engine.stdin.write(command + "\n")
        self.engine.stdin.flush()

    def through(self, prefix):
        observed = []
        deadline = monotonic() + 10
        while True:
            try:
                line = self.lines.get(timeout=max(0, deadline - monotonic()))
            except queue.Empty:
                self.fail(f"Timed out waiting for {prefix!r}. Received {observed!r}")
            self.assertIsNotNone(line, f"Engine exited while waiting for {prefix!r}: {observed!r}")
            observed.append(line)
            if line.startswith(prefix):
                return observed

    def test_infinite_mate_waits_for_stop_and_sends_one_bestmove(self):
        fen = "7k/8/5KQ1/8/8/8/8/8 w - - 0 1"
        self.send("position fen " + fen)
        self.send("go infinite")
        self.through("info depth 1 score mate 1")
        self.send("isready")
        self.assertEqual(self.through("readyok"), ["readyok"])
        self.send("stop")
        answer, = self.through("bestmove ")
        board = chess.Board(fen)
        board.push_uci(answer.split()[1])
        self.assertTrue(board.is_checkmate())
        self.send("stop")
        self.send("isready")
        self.assertEqual(self.through("readyok"), ["readyok"])

    def test_searchmoves_restricts_the_root_and_resets_for_each_go(self):
        self.send("position startpos")
        for command, permitted in [
            ("go depth 2 searchmoves e2e4", {"e2e4"}),
            ("go searchmoves d2d4 d2d4 g1f3 nodes 1", {"d2d4", "g1f3"}),
            ("go searchmoves e2e5 depth 1", {"0000"}),
        ]:
            with self.subTest(command=command):
                self.send(command)
                self.assertIn(self.through("bestmove ")[-1].split()[1], permitted)
        self.send("go infinite searchmoves a2a3")
        self.send("stop")
        self.assertEqual(self.through("bestmove ")[-1], "bestmove a2a3")
        self.send("go depth 1")
        move = self.through("bestmove ")[-1].split()[1]
        self.assertIn(chess.Move.from_uci(move), chess.Board().legal_moves)
