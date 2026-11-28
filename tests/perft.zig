const std = @import("std");
const pollock = @import("pollock");
const Move = pollock.Move;
const Piece = pollock.Piece;
const Position = pollock.Position;

fn expectBoard(expected: *const Position, actual: *const Position) !void {
    const check = std.testing;
    try check.expectEqualDeep(expected.board, actual.board);
    try check.expectEqualDeep(expected.type_occupancy, actual.type_occupancy);
    try check.expectEqualDeep(expected.color_occupancy, actual.color_occupancy);
    try check.expectEqual(expected.game_ply, actual.game_ply);
    try check.expectEqual(expected.sideToMove(), actual.sideToMove());
    try check.expectEqual(expected.chess960, actual.chess960);
    try check.expectEqual(expected.castlingRights(), actual.castlingRights());
    try check.expectEqual(expected.enPassantSquare(), actual.enPassantSquare());
    try check.expectEqual(expected.state.halfmove_clock, actual.state.halfmove_clock);
    try check.expectEqual(expected.zobristKey(), actual.zobristKey());
    try check.expectEqual(expected.checkers(), actual.checkers());
    try check.expectEqualDeep(expected.state.blockers, actual.state.blockers);
    try check.expectEqual(expected.allThreats(), actual.allThreats());
    try check.expectEqualDeep(expected.state.threats, actual.state.threats);
}

fn checkMove(fen: []const u8, chess960: bool, move: Move, expected_fen: []const u8, captured: ?Piece) !void {
    var position: Position = undefined;
    var root: Position.State = undefined;
    _ = try position.setFen(&root, fen, chess960);
    var moves_buffer: [Move.max_moves]Move = undefined;
    var moves: pollock.move_generation.MoveList = .initBuffer(&moves_buffer);
    pollock.move_generation.generateLegalMoves(&position, &moves, .all);
    try std.testing.expect(std.mem.indexOfScalar(Move, moves.items, move) != null);

    // Snapshot an already populated attack cache to verify that descendants cannot overwrite it.
    _ = position.allThreats();
    var before_state = root;
    var before = position;
    before.state = &before_state;

    var child: Position.State = undefined;
    position.doMove(move, &child);
    try std.testing.expect(child.previous_state.? == &root);
    try std.testing.expectEqual(captured, child.captured_piece);
    try std.testing.expectEqual(pollock.bitboard.empty, child.all_threats);
    var expected: Position = undefined;
    var expected_state: Position.State = undefined;
    _ = try expected.setFen(&expected_state, expected_fen, chess960);
    try expectBoard(&expected, &position);

    const child_key = child.zobrist_key;
    position.undoMove(move);
    try std.testing.expect(position.state == &root);
    try std.testing.expectEqual(child_key, child.zobrist_key);
    try std.testing.expectEqualDeep(before_state, root);
    try expectBoard(&before, &position);
}

test "perft traverses and restores the start position and Kiwipete" {
    var position: Position = undefined;
    var root: Position.State = undefined;
    position.setStartPosition(&root);
    const start_key = position.zobristKey();
    try std.testing.expectEqual(@as(u64, 197281), pollock.perft.perft(&position, 4));
    try std.testing.expect(position.state == &root);
    try std.testing.expectEqual(start_key, position.zobristKey());
    position.setKiwipetePosition(&root);
    try std.testing.expectEqual(@as(u64, 97862), pollock.perft.perft(&position, 3));
}

test "capture revokes both rook rights and undo restores the board and hash" {
    try checkMove("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 7 12", false, .normal(.a1, .a8), "R3k2r/8/8/8/8/8/8/4K2R b Kk - 0 12", .black_rook);
}

test "all quiet and capture promotions round-trip" {
    for (std.enums.values(Move.Promotion)) |promotion| {
        const quiet = Move.promotion(.c7, .c8, promotion);
        const take = Move.promotion(.c7, .b8, promotion);
        const promoted = Piece.create(.white, quiet.promotionType()).toChar();
        var buffer: [80]u8 = undefined;
        const fen = "1r5k/2P5/8/8/8/8/8/4K3 w - - 4 27";
        try checkMove(fen, false, quiet, try std.fmt.bufPrint(&buffer, "1r{c}4k/8/8/8/8/8/8/4K3 b - - 0 27", .{promoted}), null);
        try checkMove(fen, false, take, try std.fmt.bufPrint(&buffer, "1{c}5k/8/8/8/8/8/8/4K3 b - - 0 27", .{promoted}), .black_rook);
    }
}

test "en passant removes the pawn from its own rank in either direction" {
    const white = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 10";
    try checkMove(white, false, .enPassant(.e5, .d6), "4k3/8/3P4/8/8/8/8/4K3 b - - 0 10", .black_pawn);
    try checkMove(white, false, .normal(.e1, .f1), "4k3/8/8/3pP3/8/8/8/5K2 b - - 1 10", null);
    try checkMove("4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 10", false, .enPassant(.e4, .d3), "4k3/8/8/8/8/3p4/8/4K3 w - - 0 11", .white_pawn);
}

test "only a legally capturable double push gets an en passant key" {
    try checkMove("4k3/8/8/8/3p4/8/4P3/4K3 w - - 13 1", false, .normal(.e2, .e4), "4k3/8/8/8/3pP3/8/8/4K3 b - e3 0 1", null);
    try checkMove("8/6p1/8/r4P1K/8/8/8/4k3 b - - 0 1", false, .normal(.g7, .g5), "8/8/8/r4PpK/8/8/8/4k3 w - - 0 2", null);
    // The first candidate (c5) is pinned. The second one (e5) makes d6 a legal target.
    const fen = "2r4k/3p4/8/2P1P3/8/8/8/2K5 b - - 0 1";
    const push = Move.normal(.d7, .d5);
    try checkMove(fen, false, push, "2r4k/8/8/2PpP3/8/8/8/2K5 w - d6 0 2", null);
    var position: Position = undefined;
    var root: Position.State = undefined;
    var next: Position.State = undefined;
    _ = try position.setFen(&root, fen, false);
    position.doMove(push, &next);
    var storage: [Move.max_moves]Move = undefined;
    var moves: pollock.move_generation.MoveList = .initBuffer(&storage);
    pollock.move_generation.generateLegalMoves(&position, &moves, .all);
    try std.testing.expect(std.mem.indexOfScalar(Move, moves.items, .enPassant(.c5, .d6)) == null);
    try std.testing.expect(std.mem.indexOfScalar(Move, moves.items, .enPassant(.e5, .d6)) != null);
}

test "castling supports ordinary and overlapping Chess960 destinations" {
    try checkMove("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 7 12", false, .castle(.e1, .h1), "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 8 12", null);
    const white_finish = "4k3/8/8/8/8/8/8/5RK1 b - - 4 11";
    try checkMove("4k3/8/8/8/8/8/8/5KR1 w G - 3 11", true, .castle(.f1, .g1), white_finish, null);
    try checkMove("4k3/8/8/8/8/8/8/6KR w H - 3 11", true, .castle(.g1, .h1), white_finish, null);
    try checkMove("4k3/8/8/8/8/8/8/4KR2 w F - 3 11", true, .castle(.e1, .f1), white_finish, null);
    try checkMove("2rk4/8/8/8/8/8/8/7K b c - 1 14", true, .castle(.d8, .c8), "2kr4/8/8/8/8/8/8/7K w - - 2 15", null);
}

test "repetition counts prior equal positions and undo restores the whole history" {
    var position: Position = undefined;
    var states: [10]Position.State = undefined;
    position.setStartPosition(&states[0]);
    const moves = [_]Move{
        .normal(.g1, .f3), .normal(.g8, .f6), .normal(.f3, .g1), .normal(.f6, .g8),
        .normal(.g1, .f3), .normal(.g8, .f6), .normal(.f3, .g1), .normal(.f6, .g8),
        .normal(.e2, .e4),
    };
    const counts = [_]u32{ 0, 0, 0, 1, 1, 1, 1, 2, 0 };
    for (moves, counts, 1..) |move, count, ply| {
        position.doMove(move, &states[ply]);
        try std.testing.expectEqual(count, position.state.repetition);
        try std.testing.expectEqual(@as(u32, if (ply == 9) 0 else @intCast(ply)), position.state.halfmove_clock);
    }
    var ply = moves.len;
    while (ply > 0) {
        ply -= 1;
        position.undoMove(moves[ply]);
        try std.testing.expect(position.state == &states[ply]);
        try std.testing.expectEqual(ply, position.game_ply);
    }
}
