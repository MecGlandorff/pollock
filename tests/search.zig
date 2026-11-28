const std = @import("std");
const p = @import("pollock");
const Position = p.Position;
const Move = p.Move;

test "null move clears en passant and creates its own repetition window" {
    var b: Position = undefined;
    var root: Position.State = undefined;
    _ = try b.setFen(&root, "4k1n1/8/8/3pP3/8/8/8/4K1N1 w - d6 7 20", false);
    _ = b.allThreats();
    const before = root;
    const ply = b.game_ply;

    var pass: Position.State = undefined;
    b.doNullMove(&pass);
    try std.testing.expect(b.state == &pass and pass.previous_state.? == &root);
    try std.testing.expectEqual(p.Color.black, b.sideToMove());
    try std.testing.expectEqual(ply + 1, b.game_ply);
    try std.testing.expectEqual(@as(?p.Square, null), b.enPassantSquare());
    try std.testing.expectEqual(@as(u32, 0), pass.halfmove_clock);
    try std.testing.expectEqual(@as(u32, 0), pass.repetition);
    var fresh: Position = undefined;
    var fresh_state: Position.State = undefined;
    _ = try fresh.setFen(&fresh_state, "4k1n1/8/8/3pP3/8/8/8/4K1N1 b - - 0 20", false);
    try std.testing.expectEqual(fresh.zobristKey(), b.zobristKey());
    try std.testing.expectEqual(fresh.allThreats(), b.allThreats());
    try std.testing.expectEqualDeep(fresh.state.blockers, b.state.blockers);

    const cycle = [_]Move{ .normal(.g8, .f6), .normal(.g1, .f3), .normal(.f6, .g8), .normal(.f3, .g1) };
    var states: [cycle.len]Position.State = undefined;
    for (cycle, &states, 0..) |m, *state, i| {
        b.doMove(m, state);
        try std.testing.expectEqual(@as(u32, @intFromBool(i == 3)), state.repetition);
    }
    var i = cycle.len;
    while (i != 0) {
        i -= 1;
        b.undoMove(cycle[i]);
    }
    try std.testing.expect(b.state == &pass);
    b.undoNullMove();
    try std.testing.expect(b.state == &root);
    try std.testing.expectEqualDeep(before, root);
    try std.testing.expectEqual(ply, b.game_ply);
    try std.testing.expectEqual(p.Color.white, b.sideToMove());
}

test "search restores the root after a completed depth, node limit and stop" {
    var b: Position = undefined;
    var state: Position.State = undefined;
    b.setStartPosition(&state);
    const board = b.board;
    const key = b.zobristKey();
    const cache = state.all_threats;
    var table: [2048]p.search.Entry = @splat(.{});
    var engine = p.search.Engine{ .io = std.testing.io, .table = &table };
    const result = engine.run(&b, null, &.{}, .{ .depth = 3 });
    try std.testing.expectEqual(@as(u8, 3), result.depth);
    const limited = engine.run(&b, null, &.{}, .{ .nodes = 100 });
    // A pending PVS re-search can visit one more node while unwinding a stop.
    // The reference also reports 101 nodes for this 100-node budget.
    try std.testing.expect(limited.nodes >= 100 and limited.nodes <= 101);
    engine.stop.store(true, .release);
    const stopped = engine.run(&b, null, &.{}, .{});
    try std.testing.expectEqual(@as(u8, 0), stopped.depth);
    try std.testing.expect(stopped.best != null);
    try std.testing.expect(b.state == &state);
    try std.testing.expectEqual(@as(usize, 0), b.game_ply);
    try std.testing.expectEqualDeep(board, b.board);
    try std.testing.expectEqual(key, b.zobristKey());
    try std.testing.expectEqual(cache, state.all_threats);
    var backing: [Move.max_moves]Move = undefined;
    var legal: p.movegen.MoveList = .initBuffer(&backing);
    p.movegen.generateLegalMoves(&b, &legal, .all);
    for ([_]p.search.Result{ result, limited, stopped }) |r|
        try std.testing.expect(std.mem.indexOfScalar(Move, legal.items, r.best.?) != null);
}

test "two occurrences before the root are required for a game-history draw" {
    // A rook shuttles between a3 and a2, the black king between h8 and g8.
    var b: Position = undefined;
    var start: Position.State = undefined;
    _ = try b.setFen(&start, "7k/8/8/8/8/R7/8/K7 b - - 0 1", false);
    const cycle = [_]Move{ .normal(.h8, .g8), .normal(.a3, .a2), .normal(.g8, .h8), .normal(.a2, .a3) };
    var past: [7]u64 = undefined;
    var states: [7]Position.State = undefined;
    var table: [2048]p.search.Entry = @splat(.{});
    var engine = p.search.Engine{ .io = std.testing.io, .table = &table };
    const limits = p.search.Limits{ .root_moves = &.{cycle[3]}, .depth = 1 };
    for (&states, &past, 0..) |*state, *key, i| {
        key.* = b.zobristKey();
        b.doMove(cycle[i % cycle.len], state);
        if (i == 2 or i == 6) {
            engine.reset();
            const result = engine.run(&b, null, past[0 .. i + 1], limits);
            try std.testing.expectEqual(cycle[3], result.best.?);
            if (i == 2) {
                try std.testing.expect(result.score > 400);
            } else {
                try std.testing.expectEqual(@as(i32, 0), result.score);
            }
        }
    }
}
