"""Train a 768 → 16 → 1 NNUE from scratch on material or human game results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from time import perf_counter

import chess
import torch
from torch import nn

from arena import DEFAULT_EXE, ROOT, digest, material_cp, recorded_run, zig_scores
from games import split_games


def split_positions(path):
    positions = {}
    invalid = duplicates = 0
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # The EPD perft counts are move counts. Only the position is used here.
        board = chess.Board(line.split(";", 1)[0].strip())
        if not board.is_valid():
            invalid += 1
            continue
        layout = board.board_fen()
        if layout in positions:
            duplicates += 1
            continue
        group = min(layout, board.mirror().board_fen())
        positions[layout] = (group, board)
    groups = sorted({group for group, _ in positions.values()},
                    key=lambda g: hashlib.sha256(g.encode()).digest())
    if len(groups) < 2:
        raise ValueError("The dataset needs at least two independent board layouts")
    holdout = set(groups[:max(1, len(groups) // 5)])
    train, valid = [], []
    for group, board in positions.values():
        (valid if group in holdout else train).append(board)
    return train, valid, dict(train=len(train), holdout=len(valid), invalid=invalid, duplicates=duplicates)


def tensors(boards, targets=None):
    x = torch.zeros((len(boards), 768))
    for i, board in enumerate(boards):
        features = []
        for square, piece in board.piece_map().items():
            plane = piece.piece_type - 1 + (0 if piece.color == chess.WHITE else 6)
            features.append(64 * plane + square)
        x[i, features] = 1
    turn = torch.tensor([1 if b.turn == chess.WHITE else -1 for b in boards], dtype=torch.float32)
    if targets is None:
        targets = [material_cp(b) for b in boards]
    return x, turn, torch.tensor(targets, dtype=torch.float32)


def export(model, *, outcome=False):
    def rounded(tensor, scale):
        values = (tensor.detach() * scale).round().to(torch.int64)
        if (values.abs() > 32767).any():
            raise ValueError("Weights exceed the v0 checkpoint's integer range")
        return values.tolist()

    hidden, _, output = model
    net = dict(version=1, feature_weights=rounded(hidden.weight.T, 256),
               hidden_bias=rounded(hidden.bias, 256), output_weights=rounded(output.weight[0], 1000),
               output_bias=rounded(output.bias[0], 1000))
    if outcome:
        net["score_unit"] = "outcome_per_mille"
    return net


def exported_scores(net, x, turn):
    hidden = (x.long() @ torch.tensor(net["feature_weights"]) + torch.tensor(net["hidden_bias"])).clamp(0, 256)
    total = hidden @ torch.tensor(net["output_weights"]) + 256 * net["output_bias"]
    scores = torch.div(total, 256, rounding_mode="trunc") * turn.long()
    if net.get("score_unit") == "outcome_per_mille":
        scores = scores.clamp(-1000, 1000)
    return scores


def train(args):
    started = perf_counter()
    device = torch.device(args.device)
    cuda = device.type == "cuda"
    outcome = args.pgn is not None
    source = args.pgn if outcome else args.positions
    exe = args.pollock.resolve()
    settings = dict(seed=args.seed, epochs=args.epochs, torch=str(torch.__version__),
                    batch_size=args.batch_size, learning_rate=0.003, device=device.type,
                    device_name=torch.cuda.get_device_name(device) if cuda else "CPU",
                    cuda_build=torch.version.cuda, cpu_threads=1,
                    target="signed game result for side to move" if outcome else "material in centipawns for side to move")
    if outcome:
        settings["max_games"] = args.max_games
    with recorded_run(args.out, exe, [source], settings) as report:
        print(f"Training on {settings['device_name']} ({device.type})", flush=True)
        torch.set_num_threads(1)
        torch.use_deterministic_algorithms(True)
        torch.manual_seed(args.seed)
        if outcome:
            train_games, valid_games, report["positions"] = split_games(source, args.max_games)
            train_boards, train_values = zip(*train_games)
            valid_boards, valid_values = zip(*valid_games)
        else:
            train_boards, valid_boards, report["positions"] = split_positions(source)
            train_values = valid_values = None
        train_x, train_turn, train_target = tensors(train_boards, train_values)
        valid_x, valid_turn, valid_target = tensors(valid_boards, valid_values)

        # The CPU seed controls initialization and minibatch order on both devices.
        model = nn.Sequential(nn.Linear(768, 16), nn.Hardtanh(0, 1), nn.Linear(16, 1))
        with torch.no_grad():
            initial = model(valid_x).flatten() * valid_turn
        if outcome:
            mean_result = train_target.mean()
            report["train_mean_outcome"] = mean_result.item()
            report["baseline_mse"] = (mean_result - valid_target).square().mean().item()
            report["untrained_mse"] = (initial.clamp(-1, 1) - valid_target).square().mean().item()
        else:
            report["untrained_mae_cp"] = (initial * 1000 - valid_target).abs().mean().item()
            train_target = train_target / 1000

        model.to(device)
        train_x, train_turn, train_target = train_x.to(device), train_turn.to(device), train_target.to(device)
        optimizer = torch.optim.Adam(model.parameters(), lr=settings["learning_rate"])
        if cuda:
            torch.cuda.synchronize(device)
        training_started = perf_counter()
        for _ in range(args.epochs):
            order = torch.randperm(len(train_boards)).to(device)
            for indices in order.split(args.batch_size):
                predicted = model(train_x[indices]).flatten() * train_turn[indices]
                loss = (predicted - train_target[indices]).square().mean()
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()
        if cuda:
            torch.cuda.synchronize(device)
        report["train_seconds"] = perf_counter() - training_started

        model.cpu()
        optimizer_state = optimizer.state_dict()
        for slots in optimizer_state["state"].values():
            for name, value in slots.items():
                if isinstance(value, torch.Tensor):
                    slots[name] = value.cpu()
        torch.save(dict(model=model.state_dict(), optimizer=optimizer_state, epochs=args.epochs,
                        rng=torch.get_rng_state(), target=settings["target"]), args.out / "checkpoint.pt")
        net = export(model, outcome=outcome)
        weights = args.out / "network.pending.json"
        weights.write_text(json.dumps(net, separators=(",", ":")) + "\n", encoding="utf-8", newline="\n")
        reference = exported_scores(net, valid_x, valid_turn)
        fens = [b.fen(en_passant="fen") for b in valid_boards]
        actual = zig_scores(exe, weights, fens)
        for fen, python_score, zig_score in zip(fens, reference.tolist(), actual, strict=True):
            if python_score != zig_score:
                raise ValueError(f"{fen}: Python {python_score}, Zig {zig_score}")
        with torch.no_grad():
            floating = model(valid_x).flatten() * valid_turn
        report.update(zig_scores_matched=len(actual), weights_sha256=digest(weights),
                      checkpoint_sha256=digest(args.out / "checkpoint.pt"))
        print(f"{len(train_boards)} training positions, {len(valid_boards)} held out")
        if outcome:
            result = reference.float() / 1000
            report["heldout_mse"] = (result - valid_target).square().mean().item()
            report["quantization_mae_outcome"] = (result - floating.clamp(-1, 1)).abs().mean().item()
            print(f"Outcome MSE {report['heldout_mse']:.4f}, training-mean baseline {report['baseline_mse']:.4f}")
        else:
            report["heldout_mae_cp"] = (reference - valid_target).abs().mean().item()
            report["quantization_mae_cp"] = (reference - floating * 1000).abs().mean().item()
            print(f"Material MAE {report['untrained_mae_cp']:.1f} -> {report['heldout_mae_cp']:.1f} cp")
        weights.replace(args.out / "network.json")
        report["total_seconds"] = perf_counter() - started
        print(f"Python and Zig agreed on all {len(actual)} integer scores.")
        print(f"Training {report['train_seconds']:.2f}s, total {report['total_seconds']:.2f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--positions", type=Path, default=ROOT / "tests/perft/marcel.epd", help="EPD for material training")
    sources.add_argument("--pgn", type=Path, help="UTF-8 PGN of human games for outcome training")
    parser.add_argument("--max-games", type=int, help="maximum eligible games to use with --pgn (default 4096)")
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cpu")
    parser.add_argument("--out", required=True, type=Path, help="new directory for weights and run record")
    parser.add_argument("--pollock", type=Path, default=DEFAULT_EXE)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=128)
    args = parser.parse_args()
    if args.epochs < 1 or args.batch_size < 1:
        parser.error("--epochs and --batch-size must be positive")
    if args.max_games is None:
        args.max_games = 4096
    elif args.pgn is None or args.max_games < 2:
        parser.error("--max-games requires --pgn and a limit of at least two")
    if args.device == "cuda":
        os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
        if not torch.cuda.is_available():
            parser.error("CUDA was requested but is unavailable. Check nvidia-smi and run uv with --extra cuda.")
    train(args)


if __name__ == "__main__":
    main()
