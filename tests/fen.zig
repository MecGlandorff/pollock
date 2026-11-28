const std = @import("std");
const pollock = @import("pollock");
const Position = pollock.Position;
const Square = pollock.Square;

test "UCI normalizes spaces and tabs around FEN fields and before moves" {
    var position: Position = undefined;
    var state: Position.State = undefined;
    const rest = try pollock.uci_position.readFen(
        &position,
        &state,
        " \tr3k2r/8/8/3pP3/8/8/8/R3K2R  \t w\t KQkq \td6\t 0  2\tmoves e5d6",
    );
    try std.testing.expectEqualStrings("moves e5d6", rest);

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try position.writeFen(&writer);
    try std.testing.expectEqualStrings("r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 0 2", writer.buffered());
}

test "UCI rejects adjacent kings before searching" {
    var position: Position = undefined;
    var state: Position.State = undefined;
    try std.testing.expectError(
        error.OpponentInCheck,
        pollock.uci_position.readFen(&position, &state, "8/8/8/8/8/8/4k3/4K3 w - - 0 1"),
    );
}

test "Chess960 rights retain the selected rook and orthodox UCI rejects an inner rook" {
    var inner: Position = undefined;
    var outer: Position = undefined;
    var inner_state: Position.State = undefined;
    var outer_state: Position.State = undefined;
    const pieces = "4k3/8/8/8/8/8/8/4KR1R w ";
    _ = try inner.setFen(&inner_state, pieces ++ "F - 0 1", true);
    _ = try outer.setFen(&outer_state, pieces ++ "H - 0 1", true);

    const right: pollock.Castling = .right(.white, true);
    try std.testing.expectEqual(Square.f1, inner.castlingRookSquare(right));
    try std.testing.expectEqual(Square.h1, outer.castlingRookSquare(right));
    try std.testing.expectEqual(pollock.bitboard.empty, inner.castlingPath(right) & inner.totalOccupancy());
    try std.testing.expectEqual(Square.f1.bitboard(), outer.castlingPath(right) & outer.totalOccupancy());
    try std.testing.expectError(error.UnsupportedChess960, pollock.uci_position.readFen(&inner, &inner_state, pieces ++ "F - 0 1"));
    _ = try inner.setFen(&inner_state, pieces ++ "F - 0 1", false);
    try std.testing.expectEqual(pollock.Castling.none, inner_state.castling_rights);

    const outer_key = outer.zobristKey();
    _ = try outer.setFen(&outer_state, pieces ++ "KK - 0 1", true);
    try std.testing.expectEqual(outer_key, outer.zobristKey());
}

test "FEN fullmove number must fit the ply counter" {
    var position: Position = undefined;
    var state: Position.State = undefined;
    _ = try position.setFen(&state, "4k3/8/8/8/8/8/8/4K3 b - - 0 2147483648", false);
    try std.testing.expectEqual(@as(usize, 4294967295), position.game_ply);

    const result = position.setFen(&state, "4k3/8/8/8/8/8/8/4K3 w - - 0 2147483649", false);
    if (@bitSizeOf(usize) == 32) {
        try std.testing.expectError(error.InvalidFullmoveNumber, result);
    } else {
        _ = try result;
        try std.testing.expectEqual(@as(usize, 4294967296), position.game_ply);
    }
}

test "bitboard formatter prints a square on the eighth rank" {
    const bits = Square.fromCoords(.a, .@"8").bitboard();
    try std.testing.expectEqual(Square.a8.bitboard(), bits);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try pollock.bitboard.format(bits, &writer);
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "Hex: 0x0100000000000000"));
}

test "UCI FEN and replay agree on an en passant capture exposing the king" {
    var replay = pollock.uci_position.Game.init(std.testing.allocator);
    defer replay.deinit();
    try replay.parse("fen 8/2p5/8/KP5r/8/8/8/4k3 b - - 0 1 moves c7c5");
    var external = pollock.uci_position.Game.init(std.testing.allocator);
    defer external.deinit();
    try external.parse("fen 8/8/8/KPp4r/8/8/8/4k3 w - c6 0 2 moves");
    try std.testing.expect(external.board.enPassantSquare() == null);
    try std.testing.expectEqual(replay.board.zobristKey(), external.board.zobristKey());
    try std.testing.expectError(error.IllegalMove, external.extend("b5c6"));
    try std.testing.expectEqual(replay.board.zobristKey(), external.board.zobristKey());
}

test "UCI game preserves reversible history and rejects a whole invalid suffix atomically" {
    var game = pollock.uci_position.Game.init(std.testing.allocator);
    defer game.deinit();
    try game.parse("startpos moves g1f3 g8f6");
    const saved_key = game.board.zobristKey();
    const saved_state = game.board.state;
    try std.testing.expectError(error.IllegalMove, game.extend("f3g1 e7e4"));
    try std.testing.expectEqual(saved_key, game.board.zobristKey());
    try std.testing.expect(game.board.state == saved_state);
    try game.extend("f3g1 f6g8");
    var buffer: [128]u64 = undefined;
    const past = game.previousKeys(&buffer);
    try std.testing.expectEqual(@as(usize, 4), past.len);
    try std.testing.expectEqual(game.board.zobristKey(), past[0]);
    try game.extend("e2e4");
    try std.testing.expectEqual(@as(usize, 0), game.previousKeys(&buffer).len);
}
