const std = @import("std");
const pollock = @import("pollock");
const Position = pollock.Position;
const Square = pollock.Square;

test "FEN accepts spaces and tabs around fields and before moves" {
    var position: Position = undefined;
    var state: Position.State = undefined;
    const rest = try position.setFen(
        &state,
        " \tr3k2r/8/8/3pP3/8/8/8/R3K2R  \t w\t KQkq \td6\t 0  2\tmoves e5d6",
        false,
    );
    try std.testing.expectEqualStrings("moves e5d6", rest);

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try position.writeFen(&writer);
    try std.testing.expectEqualStrings("r3k2r/8/8/3pP3/8/8/8/R3K2R w KQkq d6 0 2", writer.buffered());
}

test "FEN rejects adjacent kings" {
    var position: Position = undefined;
    var state: Position.State = undefined;
    try std.testing.expectError(
        error.OpponentInCheck,
        position.setFen(&state, "8/8/8/8/8/8/4k3/4K3 w - - 0 1", false),
    );
}

test "Chess960 keys distinguish castling rooks on the same side" {
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
    try std.testing.expect(inner.zobristKey() != outer.zobristKey());

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
    const bits = pollock.bitboard.fromCoords(.a, .@"8");
    try std.testing.expectEqual(Square.a8.bitboard(), bits);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try pollock.bitboard.format(bits, &writer);
    try std.testing.expect(std.mem.endsWith(u8, writer.buffered(), "Hex: 0x0100000000000000"));
}
