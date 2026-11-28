"""Exercise Pollock through its UCI subprocess pipes."""

import argparse
from collections import deque
from pathlib import Path
from queue import Empty, Queue
import re
import subprocess
from threading import Thread
from time import monotonic


TIMEOUT = 10.0
POSITION = "position startpos moves e2e4 e7e5 g1f3 b8c6"
# Legal replies to the four-ply opening above.
LEGAL_MOVES = set(
    "a2a3 a2a4 b1a3 b1c3 b2b3 b2b4 c2c3 c2c4 d1e2 d2d3 d2d4 e1e2 "
    "f1a6 f1b5 f1c4 f1d3 f1e2 f3d4 f3e5 f3g1 f3g5 f3h4 g2g3 g2g4 "
    "h1g1 h2h3 h2h4".split()
)


class Session:
    def __init__(self, process):
        self.process = process
        self.lines = Queue()
        self.transcript = deque(maxlen=40)
        self.reader = Thread(target=self.read_stdout, daemon=True)
        self.reader.start()

    def read_stdout(self):
        try:
            for line in self.process.stdout:
                self.lines.put(line.strip())
        finally:
            self.lines.put(None)

    def send(self, command):
        self.transcript.append(f"> {command}")
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def receive(self, deadline):
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise Empty
        line = self.lines.get(timeout=remaining)
        if line is None:
            raise AssertionError("Engine closed stdout")
        self.transcript.append(f"< {line}")
        assert not line.startswith("info string "), line
        return line

    def wait_for(self, expected, *, allow_bestmove=False):
        deadline = monotonic() + TIMEOUT
        lines = []
        try:
            while True:
                line = self.receive(deadline)
                lines.append(line)
                if line == expected or (allow_bestmove and line.startswith("bestmove ")):
                    return lines
                assert not line.startswith("bestmove "), f"Unexpected {line}"
        except Empty:
            raise AssertionError(f"Timed out waiting for {expected}") from None

    def expect_no_bestmove(self, duration):
        deadline = monotonic() + duration
        try:
            while True:
                line = self.receive(deadline)
                assert not line.startswith("bestmove "), f"Unexpected {line} before stop"
        except Empty:
            pass

    def finish_search(self, legal_moves):
        lines = self.wait_for("bestmove", allow_bestmove=True)
        fields = lines[-1].split()
        assert len(fields) == 2 and fields[1] in legal_moves, f"Invalid result {lines[-1]}"
        stats = [re.search(r"\bnodes (\d+) time (\d+)\b", line) for line in lines[:-1]]
        stats = [match for match in stats if match]
        assert stats, "Search returned no node or time information"
        nodes, elapsed = map(int, stats[-1].groups())
        assert nodes > 0, "Search did not visit any nodes"
        return nodes, elapsed


def exercise(uci, weights):
    uci.send("uci")
    handshake = uci.wait_for("uciok")
    assert any(line.startswith("id name Pollock") for line in handshake), handshake
    assert any(line.startswith("option name EvalFile type string") for line in handshake), handshake
    if weights is not None:
        uci.send(f"setoption name EvalFile value {weights}")
    uci.send("isready")
    uci.wait_for("readyok")

    uci.send("ucinewgame")
    uci.send(POSITION)
    node_budget = 2048
    uci.send(f"go nodes {node_budget} searchmoves f1b5")
    nodes, _ = uci.finish_search({"f1b5"})
    # This measured release can enter a pending re-search while stopping.
    assert node_budget <= nodes <= node_budget + 2, f"Unexpected node count {nodes}"

    for command in (
        "go movetime 100",
        "go wtime 2040 btime 60000 winc 10 binc 0 movestogo 20",
    ):
        uci.send("ucinewgame")
        uci.send(POSITION)
        uci.send(command)
        _, elapsed = uci.finish_search(LEGAL_MOVES)
        assert elapsed >= 40, f"Search ended after only {elapsed} ms for {command}"

    uci.send("go infinite")
    uci.send("isready")
    uci.wait_for("readyok")
    uci.expect_no_bestmove(0.2)
    uci.send("stop")
    uci.finish_search(LEGAL_MOVES)
    uci.send("isready")
    uci.wait_for("readyok")
    uci.send("quit")
    status = uci.process.wait(timeout=TIMEOUT)
    assert status == 0, f"Engine exited with status {status}"


def check_startup(command, option_weights):
    with subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
    ) as process:
        uci = Session(process)
        try:
            exercise(uci, option_weights)
        except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
            raise SystemExit(f"{error}\n" + "\n".join(uci.transcript)) from None
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=TIMEOUT)
            uci.reader.join(timeout=TIMEOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    parser.add_argument(
        "--weights", type=Path,
        default=Path(__file__).resolve().parents[1] / "played" / "wide1024-661m.pnn",
    )
    args = parser.parse_args()
    command = [str(args.engine.resolve()), "uci"]
    weights = args.weights.resolve(strict=True)
    check_startup(command, weights)
    check_startup([*command, "--weights", str(weights)], None)
    print("UCI smoke test passed")


if __name__ == "__main__":
    main()
