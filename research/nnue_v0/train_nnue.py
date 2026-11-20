"""Train a 768 → 16 → 1 piece-square NNUE on side-to-move material balance."""
import argparse
import hashlib
import json
from pathlib import Path

import chess
import torch
from torch import nn

from arena import DEFAULT_EXE, ROOT, digest, material_cp, recorded_run, zig_scores


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


def tensors(boards):
    x = torch.zeros((len(boards), 768))
    for i, board in enumerate(boards):
        features = []
        for square, piece in board.piece_map().items():
            plane = piece.piece_type - 1 + (0 if piece.color == chess.WHITE else 6)
            features.append(64 * plane + square)
        x[i, features] = 1
    turn = torch.tensor([1 if b.turn == chess.WHITE else -1 for b in boards], dtype=torch.float32)
    cp = torch.tensor([material_cp(b) for b in boards], dtype=torch.float32)
    return x, turn, cp


def export(model):
    def rounded(tensor, scale):
        values = (tensor.detach() * scale).round().to(torch.int64)
        if (values.abs() > 32767).any():
            raise ValueError("Weights exceed the v0 checkpoint's integer range")
        return values.tolist()

    hidden, _, output = model
    return dict(version=1, feature_weights=rounded(hidden.weight.T, 256),
                hidden_bias=rounded(hidden.bias, 256), output_weights=rounded(output.weight[0], 1000),
                output_bias=rounded(output.bias[0], 1000))


def exported_scores(net, x, turn):
    hidden = (x.long() @ torch.tensor(net["feature_weights"]) + torch.tensor(net["hidden_bias"])).clamp(0, 256)
    total = hidden @ torch.tensor(net["output_weights"]) + 256 * net["output_bias"]
    return torch.div(total, 256, rounding_mode="trunc") * turn.long()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--positions", type=Path, default=ROOT / "tests/perft/marcel.epd")
    parser.add_argument("--out", required=True, type=Path, help="new directory for weights and run record")
    parser.add_argument("--pollock", type=Path, default=DEFAULT_EXE)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--epochs", type=int, default=40)
    args = parser.parse_args()
    if args.epochs < 1:
        parser.error("--epochs must be positive")
    exe = args.pollock.resolve()
    settings = dict(seed=args.seed, epochs=args.epochs, torch=str(torch.__version__),
                    batch_size=128, learning_rate=0.003, target="material in centipawns for side to move")
    with recorded_run(args.out, exe, [args.positions], settings) as report:
        torch.set_num_threads(1)
        torch.use_deterministic_algorithms(True)
        torch.manual_seed(args.seed)
        train, valid, report["positions"] = split_positions(args.positions)
        train_x, train_turn, train_cp = tensors(train)
        valid_x, valid_turn, valid_cp = tensors(valid)
        model = nn.Sequential(nn.Linear(768, 16), nn.Hardtanh(0, 1), nn.Linear(16, 1))
        optimizer = torch.optim.Adam(model.parameters(), lr=settings["learning_rate"])
        with torch.no_grad():
            initial = model(valid_x).flatten() * valid_turn * 1000
            report["untrained_mae_cp"] = (initial - valid_cp).abs().mean().item()

        for _ in range(args.epochs):
            for indices in torch.randperm(len(train)).split(settings["batch_size"]):
                predicted = model(train_x[indices]).flatten() * train_turn[indices]
                loss = (predicted - train_cp[indices] / 1000).square().mean()
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()

        torch.save(dict(model=model.state_dict(), optimizer=optimizer.state_dict(),
                        epochs=args.epochs, rng=torch.get_rng_state()), args.out / "checkpoint.pt")
        net = export(model)
        weights = args.out / "network.json"
        weights.write_text(json.dumps(net, separators=(",", ":")) + "\n")
        reference = exported_scores(net, valid_x, valid_turn)
        fens = [b.fen(en_passant="fen") for b in valid]
        actual = zig_scores(exe, weights, fens)
        for fen, python_cp, zig_cp in zip(fens, reference.tolist(), actual, strict=True):
            if python_cp != zig_cp:
                raise ValueError(f"{fen}: Python {python_cp} cp, Zig {zig_cp} cp")
        with torch.no_grad():
            floating = model(valid_x).flatten() * valid_turn * 1000
        report.update(zig_scores_matched=len(actual), weights_sha256=digest(weights),
                      checkpoint_sha256=digest(args.out / "checkpoint.pt"),
                      heldout_mae_cp=(reference - valid_cp).abs().mean().item(),
                      quantization_mae_cp=(reference - floating).abs().mean().item())
        print(f"{len(train)} training positions, {len(valid)} held out")
        print(f"Material MAE {report['untrained_mae_cp']:.1f} -> {report['heldout_mae_cp']:.1f} cp")
        print(f"Python and Zig agreed on all {len(actual)} integer scores.")


if __name__ == "__main__":
    main()
