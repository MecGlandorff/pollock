const std = @import("std");
const p = @import("pollock");
const mg = p.movegen;

fn parse(fen: []const u8, state: *p.Position.State) !p.Position {
    var pos: p.Position = undefined;
    const rest = try pos.setFen(state, fen, false);
    try std.testing.expect(rest.len == 0);
    return pos;
}

fn legalMove(pos: *p.Position, notation: []const u8) !p.Move {
    var storage: [p.Move.max_moves]p.Move = undefined;
    var moves: mg.MoveList = .initBuffer(&storage);
    mg.generateLegalMoves(pos, &moves, .all);
    for (moves.items) |move| {
        var chars: [5]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&chars);
        try move.print(pos.chess960, &writer);
        if (std.mem.eql(u8, notation, writer.buffered())) return move;
    }
    return error.IllegalTestMove;
}

fn hasLegal(pos: *p.Position) bool {
    var storage: [p.Move.max_moves]p.Move = undefined;
    var moves: mg.MoveList = .initBuffer(&storage);
    mg.generateLegalMoves(pos, &moves, .all);
    return moves.items.len != 0;
}

test "orthodox perft, castling and en passant" {
    const fixtures = [_]struct { fen: []const u8, depth: u8, nodes: u64 }{
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .depth = 4, .nodes = 197281 },
        .{ .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 3, .nodes = 97862 },
        .{ .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 4, .nodes = 43238 },
    };
    for (fixtures) |case| {
        var state: p.Position.State = undefined;
        var board = try parse(case.fen, &state);
        try std.testing.expectEqual(case.nodes, p.perft.perft(&board, case.depth));
    }
}

test "double push and en passant preserve hash and incremental accumulator" {
    var net = std.mem.zeroes(p.nnue.Network);
    net.version = 1;
    for (&net.feature_weights, 0..) |*row, i| {
        for (row, 0..) |*w, j| w.* = @intCast(@as(i32, @intCast((i + 7 * j) % 43)) - 21);
    }
    var states: [6]p.Position.State = undefined;
    var board: p.Position = undefined;
    board.setStartPosition(&states[0]);
    var layer = net.refresh(&board);
    const line = [_][]const u8{ "e2e4", "a7a6", "e4e5", "d7d5", "e5d6" };
    for (line, 1..) |notation, ply| {
        const move = try legalMove(&board, notation);
        const before = board;
        board.doMove(move, &states[ply]);
        net.update(&layer, &before, &board);
        if (ply >= 4) {
            var expected_state: p.Position.State = undefined;
            const expected = try parse(if (ply == 4)
                "rnbqkbnr/1pp1pppp/p7/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"
            else
                "rnbqkbnr/1pp1pppp/p2P4/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3", &expected_state);
            try std.testing.expectEqual(expected.zobristKey(), board.zobristKey());
            try std.testing.expectEqualSlices(i32, &net.refresh(&expected).values, &layer.values);
        }
    }
}

test "king-relative incremental evaluation matches refresh across exceptional moves" {
    const allocator = std.testing.allocator;
    var wrapper = std.mem.zeroes(p.nnue.Network);
    wrapper.version = 2;
    const net = try allocator.create(p.king_nnue.Network);
    wrapper.king_net = net;
    defer wrapper.deinit(allocator);
    for (&net.feature_weights, 0..) |*bucket, k| {
        for (bucket, 0..) |*row, i| {
            for (row, 0..) |*w, j| w.* = @intCast(@as(i32, @intCast((i * 7 + j * 11 + k * 13) % 59)) - 29);
        }
    }
    @memset(&net.hidden_bias, 63);
    for (&net.output_weights, 0..) |*row, k| {
        for (row, 0..) |*w, i| w.* = @intCast(@as(i32, @intCast(k * 13 + i * 3)) - 37);
    }
    net.tempo = .{ 7, 12, 16 };
    net.pawn_weights = @splat(@splat(1));
    var imbalance: p.king_nnue.Acc = .{};
    imbalance.values[1][21] = 230;
    // The White perspective has fewer active features on this lane.
    try std.testing.expectEqual(@as(i32, -16), net.score(&imbalance, 0, 0, 0));
    try expectSpecialMoveRefresh(&wrapper);
}

test "wide incremental evaluation matches refresh across exceptional moves" {
    const allocator = std.testing.allocator;
    // Spread the 128 channels of the reference fixture across the full evaluator.
    // Each group shares input features and contributes its output exactly once.
    const reference_width = 128;
    const group_width = @divExact(p.wide_nnue.width, reference_width);
    var wrapper = std.mem.zeroes(p.nnue.Network);
    wrapper.version = 3;
    const net = try allocator.create(p.wide_nnue.Network);
    wrapper.wide_net = net;
    defer wrapper.deinit(allocator);
    for (&net.feature_weights, 0..) |*bucket, k| {
        for (bucket, 0..) |*row, i| {
            for (row, 0..) |*w, j| {
                const lane = j / group_width;
                w.* = @intCast(@as(i32, @intCast((i * 7 + lane * 11 + k * 13) % 59)) - 29);
            }
        }
    }
    @memset(&net.hidden_bias, 63);
    for (&net.output_weights, 0..) |*head, h| {
        for (head, 0..) |*row, s| {
            for (row, 0..) |*w, i| {
                const lane = i / group_width;
                w.* = if (i % group_width == group_width - 1)
                    @intCast(@as(i32, @intCast((lane * 3 + s * 7 + h * 13) % 27)) - 12)
                else
                    0;
            }
        }
    }
    @memset(&net.output_bias, 11);
    try net.prepareOutput();
    try expectSpecialMoveRefresh(&wrapper);
    var valid: p.Position = undefined;
    var invalid: p.Position = undefined;
    var valid_state: p.Position.State = undefined;
    var invalid_state: p.Position.State = undefined;
    valid.setStartPosition(&valid_state);
    _ = try invalid.setFen(&invalid_state, "rnbqkbnr/pppppppp/8/8/8/Q7/PPPPPPPP/RNBQKBNR w KQkq - 0 1", false);
    try std.testing.expectError(error.InvalidPieceCount, wrapper.refreshChecked(&invalid));
    const original = wrapper.refresh(&valid);
    var state = original;
    try std.testing.expectError(error.InvalidPieceCount, wrapper.updateChecked(&state, &valid, &invalid));
    try std.testing.expectEqualDeep(original, state);
}

test "wide loader verifies dimensions and accumulator bounds and scores large heads safely" {
    const allocator = std.testing.allocator;
    const width = p.wide_nnue.width;
    const tail = 16 + 8 * 768 * width * 2;
    const head_start = tail + 2 * width;
    const bytes = try allocator.alloc(u8, head_start + 8 * 2 * width * 2 + 8 * 4);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], p.wide_nnue.magic);
    try std.testing.expectError(error.InvalidWideNetwork, p.wide_nnue.Network.load(allocator, bytes));
    inline for ([_]u16{ 8, 768, width, 8 }, 0..) |v, i| std.mem.writeInt(u16, bytes[8 + i * 2 ..][0..2], v, .little);
    std.mem.writeInt(i16, bytes[16..18], 1024, .little);
    try std.testing.expectError(error.WideAccumulatorOverflow, p.wide_nnue.Network.load(allocator, bytes));
    std.mem.writeInt(i16, bytes[16..18], 0, .little);
    for (0..width) |i| {
        std.mem.writeInt(i16, bytes[head_start + 2 * i ..][0..2], 32767, .little);
        std.mem.writeInt(i16, bytes[head_start + 2 * (width + i) ..][0..2], -32768, .little);
    }
    const net = try p.wide_nnue.Network.load(allocator, bytes);
    defer allocator.destroy(net);
    try std.testing.expect(!net.fast_sum[0]);
    var accum: p.wide_nnue.Acc = .{};
    @memset(&accum.values[0], 255);
    try std.testing.expectEqual(@as(i32, 32767 * width), net.score(&accum, 0, 2, 0));
    try std.testing.expectEqual(@as(i32, -32768 * width), net.score(&accum, 0, 2, 1));
}

fn expectSpecialMoveRefresh(wrapper: *const p.nnue.Network) !void {
    // History-malus 8825d804, synthetic weights above. Each quartet lists white/black before and after.
    const cases = [_]struct {
        before: []const u8,
        move: []const u8,
        after: []const u8,
        chess960: bool = false,
        king_scores: [4]i32,
        wide_scores: [4]i32,
    }{
        .{
            .before = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
            .move = "e5d6",
            .after = "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1",
            .king_scores = .{ 21, -7, 102, -88 },
            .wide_scores = .{ 20, 19, 117, -86 },
        },
        .{
            .before = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
            .move = "e1c1",
            .after = "r3k2r/8/8/8/8/8/8/2KR3R b kq - 1 1",
            .king_scores = .{ 12, 12, 14, 10 },
            .wide_scores = .{ 40, 40, 43, 38 },
        },
        .{
            .before = "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1",
            .move = "e8g8",
            .after = "r4rk1/8/8/8/8/8/8/R3K2R w KQ - 1 2",
            .king_scores = .{ 12, 12, 24, 0 },
            .wide_scores = .{ 40, 40, 42, 44 },
        },
        .{
            .before = "8/3k4/8/3Q4/8/4K3/8/8 b - - 0 1",
            .move = "d7e8",
            .after = "4k3/8/8/3Q4/8/4K3/8/8 w - - 1 2",
            .king_scores = .{ 918, -904, 916, -902 },
            .wide_scores = .{ 919, -881, 916, -885 },
        },
        .{
            .before = "3r3k/4P3/8/8/8/8/8/1K6 w - - 0 1",
            .move = "e7d8n",
            .after = "3N3k/8/8/8/8/8/8/1K6 b - - 0 1",
            .king_scores = .{ -377, 391, 336, -322 },
            .wide_scores = .{ -386, 421, 344, -304 },
        },
        .{
            .before = "4k3/8/8/8/8/8/8/5KR1 w G - 0 1",
            .move = "f1g1",
            .after = "4k3/8/8/8/8/8/8/5RK1 b - - 1 1",
            .chess960 = true,
            .king_scores = .{ 508, -494, 519, -505 },
            .wide_scores = .{ 515, -477, 511, -483 },
        },
        .{
            .before = "2rk4/8/8/8/8/8/8/7K b c - 0 1",
            .move = "d8c8",
            .after = "2kr4/8/8/8/8/8/8/7K w - - 1 2",
            .chess960 = true,
            .king_scores = .{ -495, 509, -491, 505 },
            .wide_scores = .{ -484, 515, -481, 522 },
        },
    };
    for (cases) |case| {
        var position: p.Position = undefined;
        var expected: p.Position = undefined;
        var root_state: p.Position.State = undefined;
        var child_state: p.Position.State = undefined;
        var expected_state: p.Position.State = undefined;
        _ = try position.setFen(&root_state, case.before, case.chess960);
        _ = try expected.setFen(&expected_state, case.after, case.chess960);
        const scores = if (wrapper.wide_net != null) case.wide_scores else case.king_scores;
        var public = try wrapper.refreshChecked(&position);
        try expectBothPerspectives(wrapper, &public, scores[0..2]);
        const move = try legalMove(&position, case.move);
        const before = position;
        position.doMove(move, &child_state);
        try std.testing.expectEqual(expected.zobristKey(), position.zobristKey());
        try wrapper.updateChecked(&public, &before, &position);
        try expectBothPerspectives(wrapper, &public, scores[2..4]);
        try std.testing.expectEqualDeep(wrapper.refresh(&expected), public);
        if (wrapper.wide_net) |net| {
            const parent = p.board_eval.refresh(&before, net);
            const child = p.board_eval.advance(&position, move, &parent, net);
            try std.testing.expectEqualDeep(p.board_eval.refresh(&expected, net), child);
            try std.testing.expectEqual(scores[2 + @as(usize, @backingInt(position.sideToMove()))], p.board_eval.score(&position, &child, net));
        }
        position.undoMove(move);
        try wrapper.updateChecked(&public, &expected, &position);
        try expectBothPerspectives(wrapper, &public, scores[0..2]);
    }
}

fn expectBothPerspectives(net: *const p.nnue.Network, layer: *const p.nnue.Accumulator(16), expected: *const [2]i32) !void {
    inline for (std.enums.values(p.Color)) |side| {
        try std.testing.expectEqual(@as(i64, expected[@backingInt(side)]), net.score(layer, side));
    }
}

test "restricted root does not cache its score for an unrestricted search" {
    var table: [2048]p.search.Entry = @splat(.{});
    var engine = p.search.Engine{ .io = std.testing.io, .table = &table };
    var state: p.Position.State = undefined;
    var board = try parse("7k/8/5KQ1/8/8/8/8/8 w - - 0 1", &state);
    const allowed = [_]p.Move{try legalMove(&board, "g6e8")};
    const restricted = engine.run(&board, null, &.{}, .{ .depth = 1, .root_moves = &allowed });
    try std.testing.expectEqual(allowed[0], restricted.best.?);
    const key = board.zobristKey();
    const entry = table[@as(usize, @truncate(key)) & (table.len - 1)];
    try std.testing.expect(entry.bound == .empty or entry.key != key);
    const full = engine.run(&board, null, &.{}, .{ .depth = 1 });
    try std.testing.expectEqual(p.search.mate - 1, full.score);
}

test "mate, stalemate and a mating hundredth halfmove survive transposition lookups" {
    var table: [2048]p.search.Entry = @splat(.{});
    var engine = p.search.Engine{ .io = std.testing.io, .table = &table };
    var state: p.Position.State = undefined;
    var board = try parse("8/8/8/8/3b4/8/1Pk5/K1n5 w - - 0 1", &state);
    try std.testing.expect(board.checkers() == 0 and !hasLegal(&board));
    board = try parse("7k/8/8/8/r7/8/P7/K7 w - - 0 1", &state);
    try std.testing.expect(board.checkers() == 0 and hasLegal(&board));
    board = try parse("7k/5Q2/6K1/8/8/8/8/8 b - - 100 1", &state);
    try std.testing.expect(!hasLegal(&board));
    const draw = engine.run(&board, null, &.{}, .{ .depth = 3 });
    try std.testing.expect(draw.best == null);
    try std.testing.expectEqual(@as(i32, 0), draw.score);
    board = try parse("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1", &state);
    try std.testing.expect(!hasLegal(&board));
    const loss = engine.run(&board, null, &.{}, .{ .depth = 3 });
    try std.testing.expectEqual(-p.search.mate, loss.score);
    board = try parse("7k/8/5KQ1/8/8/8/8/8 w - - 99 1", &state);
    for (0..2) |_| {
        const win = engine.run(&board, null, &.{}, .{ .depth = 3 });
        const move = win.best orelse return error.NoBestMove;
        var child: p.Position.State = undefined;
        board.doMove(move, &child);
        try std.testing.expect(board.checkers() != 0 and !hasLegal(&board));
        board.undoMove(move);
        try std.testing.expectEqual(p.search.mate - 1, win.score);
    }
}
