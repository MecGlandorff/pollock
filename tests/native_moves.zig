const std = @import("std");
const p = @import("pollock");
const mg = p.movegen;

fn parse(fen: []const u8, net: ?*const p.nnue.Network) !mg.Board {
    var pos: p.Position = undefined;
    var state: p.Position.State = undefined;
    const rest = try pos.setFen(&state, fen, false);
    try std.testing.expect(rest.len == 0);
    return mg.Board.fromPosition(&pos, net);
}

test "orthodox perft, castling and en passant" {
    const fixtures = [_]struct { fen: []const u8, depth: u8, nodes: u64 }{
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .depth = 4, .nodes = 197281 },
        .{ .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 3, .nodes = 97862 },
        .{ .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 4, .nodes = 43238 },
    };
    for (fixtures) |case| {
        const b = try parse(case.fen, null);
        try std.testing.expectEqual(case.nodes, mg.perft(&b, case.depth));
    }
}

test "double push and en passant preserve hash and incremental accumulator" {
    var net = std.mem.zeroes(p.nnue.Network);
    net.version = 1;
    for (&net.feature_weights, 0..) |*row, i| {
        for (row, 0..) |*w, j| w.* = @intCast(@as(i32, @intCast((i + 7 * j) % 43)) - 21);
    }
    var b = try parse("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", &net);
    for ([_][]const u8{ "e2e4", "a7a6", "e4e5", "d7d5" }) |m|
        b = mg.playUci(&b, m, &net) orelse return error.IllegalTestMove;
    const expected = try parse("rnbqkbnr/1pp1pppp/p7/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3", &net);
    try std.testing.expectEqual(expected.hash, b.hash);
    try std.testing.expectEqualSlices(i32, &expected.layer.values, &b.layer.values);
    const capture = mg.playUci(&b, "e5d6", &net) orelse return error.IllegalTestMove;
    const after = try parse("rnbqkbnr/1pp1pppp/p2P4/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3", &net);
    try std.testing.expectEqual(after.hash, capture.hash);
    try std.testing.expectEqualSlices(i32, &after.layer.values, &capture.layer.values);
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
    var wrapper = std.mem.zeroes(p.nnue.Network);
    wrapper.version = 3;
    const net = try allocator.create(p.wide_nnue.Network);
    wrapper.wide_net = net;
    defer wrapper.deinit(allocator);
    for (&net.feature_weights, 0..) |*bucket, k| {
        for (bucket, 0..) |*row, i| {
            for (row, 0..) |*w, j| w.* = @intCast(@as(i32, @intCast((i * 7 + j * 11 + k * 13) % 59)) - 29);
        }
    }
    @memset(&net.hidden_bias, 63);
    for (&net.output_weights, 0..) |*head, h| {
        for (head, 0..) |*row, s| {
            for (row, 0..) |*w, i| w.* = @intCast(@as(i32, @intCast((i * 3 + s * 7 + h * 13) % 27)) - 12);
        }
    }
    @memset(&net.output_bias, 11);
    @memset(&net.fast_sum, true);
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
    const cases = [_]struct { before: []const u8, move: []const u8, after: []const u8 }{
        .{ .before = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", .move = "e5d6", .after = "4k3/8/3P4/8/8/8/8/4K3 b - - 0 1" },
        .{ .before = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", .move = "e1c1", .after = "r3k2r/8/8/8/8/8/8/2KR3R b kq - 1 1" },
        .{ .before = "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1", .move = "e8g8", .after = "r4rk1/8/8/8/8/8/8/R3K2R w KQ - 1 2" },
        .{ .before = "8/3k4/8/3Q4/8/4K3/8/8 b - - 0 1", .move = "d7e8", .after = "4k3/8/8/3Q4/8/4K3/8/8 w - - 1 2" },
        .{ .before = "3r3k/4P3/8/8/8/8/8/1K6 w - - 0 1", .move = "e7d8n", .after = "3N3k/8/8/8/8/8/8/1K6 b - - 0 1" },
    };
    for (cases) |case| {
        var before_pos: p.Position = undefined;
        var after_pos: p.Position = undefined;
        var before_state: p.Position.State = undefined;
        var after_state: p.Position.State = undefined;
        _ = try before_pos.setFen(&before_state, case.before, false);
        _ = try after_pos.setFen(&after_state, case.after, false);
        const before = try mg.Board.fromPosition(&before_pos, wrapper);
        const child = mg.playUci(&before, case.move, wrapper) orelse return error.IllegalTestMove;
        const expected = try mg.Board.fromPosition(&after_pos, wrapper);
        var public = wrapper.refresh(&before_pos);
        try expectBothPerspectives(wrapper, &public, &before);
        wrapper.update(&public, &before_pos, &after_pos);
        try expectBothPerspectives(wrapper, &public, &expected);
        wrapper.update(&public, &after_pos, &before_pos);
        try expectBothPerspectives(wrapper, &public, &before);
        try std.testing.expectEqual(expected.hash, child.hash);
        try std.testing.expectEqual(expected.material_cp, child.material_cp);
        try std.testing.expectEqual(expected.pawn_hash, child.pawn_hash);
        try std.testing.expectEqual(expected.nonpawn_hash, child.nonpawn_hash);
        try std.testing.expectEqual(expected.phase_count, child.phase_count);
        try std.testing.expectEqual(expected.pawn_scores, child.pawn_scores);
        if (wrapper.wide_net != null) {
            try std.testing.expectEqualDeep(expected.acc.wide, child.acc.wide);
        } else {
            try std.testing.expectEqualDeep(expected.acc.king, child.acc.king);
        }
        try std.testing.expectEqual(expected.neuralScore(wrapper), child.neuralScore(wrapper));
    }
}

fn expectBothPerspectives(net: *const p.nnue.Network, layer: *const p.nnue.Accumulator(16), board: *const mg.Board) !void {
    const opposite = board.nullChild();
    try std.testing.expectEqual(@as(i64, board.neuralScore(net)), net.score(layer, @fromBackingInt(board.side)));
    try std.testing.expectEqual(@as(i64, opposite.neuralScore(net)), net.score(layer, @fromBackingInt(opposite.side)));
}

test "restricted root does not cache its score for an unrestricted search" {
    var table: [2048]p.search.Entry = @splat(.{});
    var engine = p.search.Engine{ .io = std.testing.io, .table = &table };
    const board = try parse("7k/8/5KQ1/8/8/8/8/8 w - - 0 1", null);
    var generated: mg.List = .{};
    board.generate(false, &generated);
    var allowed: mg.List = .{};
    allowed.moves[0] = generated.findUci("g6e8").?;
    allowed.len = 1;
    const restricted = engine.run(board, null, &.{}, .{ .depth = 1, .root_moves = &allowed });
    try std.testing.expectEqual(mg.bits(allowed.moves[0]), mg.bits(restricted.best.?));
    const entry = table[@as(usize, @truncate(board.hash)) & (table.len - 1)];
    try std.testing.expect(entry.bound == .empty or entry.key != board.hash);
    const full = engine.run(board, null, &.{}, .{ .depth = 1 });
    try std.testing.expectEqual(p.search.mate - 1, full.score);
}

test "mate, stalemate and a mating hundredth halfmove survive transposition lookups" {
    var table: [2048]p.search.Entry = @splat(.{});
    var engine = p.search.Engine{ .io = std.testing.io, .table = &table };
    const pinned = try parse("8/8/8/8/3b4/8/1Pk5/K1n5 w - - 0 1", null);
    try std.testing.expect(!pinned.inCheck() and !pinned.hasLegal());
    const file_pawn = try parse("7k/8/8/8/r7/8/P7/K7 w - - 0 1", null);
    try std.testing.expect(!file_pawn.inCheck() and file_pawn.hasLegal());
    const stale = try parse("7k/5Q2/6K1/8/8/8/8/8 b - - 100 1", null);
    try std.testing.expect(!stale.hasLegal());
    const draw = engine.run(stale, null, &.{}, .{ .depth = 3 });
    try std.testing.expect(draw.best == null);
    try std.testing.expectEqual(@as(i32, 0), draw.score);
    const mated = try parse("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1", null);
    try std.testing.expect(!mated.hasLegal());
    const loss = engine.run(mated, null, &.{}, .{ .depth = 3 });
    try std.testing.expectEqual(-p.search.mate, loss.score);
    const attack = try parse("7k/8/5KQ1/8/8/8/8/8 w - - 99 1", null);
    for (0..2) |_| {
        const win = engine.run(attack, null, &.{}, .{ .depth = 3 });
        const child = attack.child(win.best orelse return error.NoBestMove, null) orelse return error.IllegalBestMove;
        try std.testing.expect(child.inCheck() and !child.hasLegal());
        try std.testing.expectEqual(p.search.mate - 1, win.score);
    }
}
