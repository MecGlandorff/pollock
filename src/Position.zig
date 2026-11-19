const std = @import("std");

const pollock = @import("pollock");
const bitboard = pollock.bitboard;
const Bitboard = bitboard.Bitboard;
const Castling = pollock.Castling;
const Color = pollock.Color;
const Piece = pollock.Piece;
const Rank = pollock.Rank;
const File = pollock.File;
const Square = pollock.Square;
const ZobristKey = pollock.ZobristKey;

const Position = @This();

state: *State,
board: std.EnumArray(Square, ?Piece),
type_occupancy: std.EnumArray(Piece.Type, Bitboard),
color_occupancy: std.EnumArray(Color, Bitboard),
castle_mask: std.EnumArray(Square, Castling),
castle_rook_square: [Castling.count]Square,
castle_path: [Castling.count]Bitboard,
game_ply: usize,
side_to_move: Color,
chess960: bool,

pub const State = struct {
    previous_state: ?*const State,
    checkers: Bitboard,
    blockers: std.EnumArray(Color, Bitboard),
    castling_rights: Castling,
    captured_piece: ?Piece,
    en_passant_square: ?Square,
    zobrist_key: ZobristKey,
    halfmove_clock: usize,
    repetition: u32,
};

/// Returns the square of the king of `color` in `position`.
pub fn kingSquare(position: *const Position, color: Color) Square {
    std.debug.assert(position.pieceOccupancy(color, .king) != bitboard.empty);

    return @fromBackingInt(@intCast(@ctz(position.pieceOccupancy(color, .king))));
}

/// Returns the piece on `square` in `position`, or `null` if no piece is present.
pub fn onSquare(position: *const Position, square: Square) ?Piece {
    return position.board.get(square);
}

/// Returns the occupancy of `color` in `position`.
pub fn colorOccupancy(position: *const Position, color: Color) Bitboard {
    return position.color_occupancy.get(color);
}

/// Returns the occupancy of the pieces of `piece_type` and `color` in `position`.
pub fn pieceOccupancy(position: *const Position, color: Color, piece_type: Piece.Type) Bitboard {
    return position.color_occupancy.get(color) & position.type_occupancy.get(piece_type);
}

/// Returns the castling mask for `square` in `position`.
pub fn castleMask(position: *const Position, square: Square) Castling {
    return position.castling_mask.get(square);
}

/// Returns the castle rook square for `castle` in `position`.
pub fn castleRookSquare(position: *const Position, castle: Castling) Square {
    return position.castle_rook_square[castle.index()];
}

/// Returns the castle path of `castle` in `position`.
pub fn castlePath(position: *const Position, castle: Castling) Bitboard {
    return position.castle_path[castle.index()];
}

pub const FenError = error{
    MissingPiecePlacement,
    MissingSideToMove,
    MissingCastling,
    MissingEnPassant,
    MissingHalfmoveClock,
    MissingFullmoveNumber,
    TooManyFiles, // rank has more than 8 squares
    TooFewFiles, // rank has fewer than 8 squares
    TooManyRanks,
    TooFewRanks,
    InvalidPiece,
    InvalidSideToMove,
    InvalidCastling,
    InvalidEnPassant,
    InvalidHalfmoveClock,
    InvalidFullmoveNumber,
};

fn addCastlingRight(position: *Position, color: Color, king_source: Square, rook_source: Square) void {
    const kingside = @backingInt(rook_source) > @backingInt(king_source);

    var right: Castling = .right(color, kingside);

    const king_destination: Square = .relative(if (kingside) .g1 else .c1, color);
    const rook_destination: Square = .relative(if (kingside) .f1 else .d1, color);

    position.state.castling_rights = position.state.castling_rights.addRight(right);
    inline for ([_]Square{ king_source, rook_source }) |sq|
        position.castling_mask.set(sq, position.castlingMask(sq).addRight(right));

    const index = right.index();
    position.castling_rook_square[index] = rook_source;
    position.castling_path[index] = Bitboard.between(king_source, king_destination).@"or"(Bitboard.between(rook_source, rook_destination)).@"and"(king_source.bitboard().@"or"(rook_source.bitboard()).not());
}

pub fn placePiece(position: *Position, piece: Piece, square: Square) void {
    std.debug.assert(position.onSquare(square) == null);

    const bb = square.bitboard();
    position.board.set(square, piece);
    position.type_occupancy.getPtr(piece.type).* |= bb;
    position.color_occupancy.getPtr(piece.color).* |= bb;
}

fn charToPiece(char: u8) ?Piece {
    return switch (char) {
        // zig fmt: off
        'P' => .white_pawn,   'p' => .black_pawn,
        'N' => .white_knight, 'n' => .black_knight,
        'B' => .white_bishop, 'b' => .black_bishop,
        'R' => .white_rook,   'r' => .black_rook,
        'Q' => .white_queen,  'q' => .black_queen,
        'K' => .white_king,   'k' => .black_king,
        // zig fmt: on
        else => null,
    };
}

/// Updates `error_offset` and returns `err` for invalid FENs.
fn failFenParsing(error_offset: ?*usize, offset: usize, err: FenError) FenError {
    if (error_offset) |*d| d.* = offset;
    return err;
}

/// Parses a FEN from the start of `input` and returns the unconsumed rest (leading whitespace removed), e.g.
/// "moves e2e4 e7e5". On error, `position` is left in an unspecified (partially filled) state.
pub fn setFen(
    position: *Position,
    state: *State,
    input: []const u8,
    error_offset: ?*usize,
) FenError![]const u8 {
    state.* = .{
        .previous_info = null,
        .checkers = .empty,
        .blockers = .initFill(.empty),
        .castling_rights = .none,
        .captured_piece = null,
        .en_passant_square = null,
        .zobrist_key = 0,
        .halfmove_clock = undefined,
        .repetition = 0,
    };

    position.* = .{
        .state = state,
        .board = .initFill(null),
        .type_occupancy = .initFill(.empty),
        .color_occupancy = .initFill(.empty),
        .castling_mask = .initFill(.none),
        .castling_rook_square = @splat(.empty),
        .castling_path = @splat(.empty),
        .side_to_move = undefined,
        .game_ply = undefined,
        .chess960 = false,
    };

    // After next(), `fields.index` is just past the returned token, so `fields.index - token.len` is the token's start
    // offset.
    var fields = std.mem.tokenizeAny(u8, input, " \t");

    // 1. Piece placement.
    const placement = fields.next() orelse
        return failFenParsing(error_offset, input.len, FenError.MissingPiecePlacement);
    const placement_start = fields.index - placement.len;

    var rank: ?Rank = .@"8";
    var file: ?File = .a;
    for (placement, placement_start..) |char, offset| switch (char) {
        '/' => {
            if (file)
                return failFenParsing(error_offset, offset, FenError.TooFewFiles);
            if (rank == .@"1")
                return failFenParsing(error_offset, offset, FenError.TooManyRanks);

            rank = rank.step(Rank.south);
            file = .a;
        },
        '1'...'8' => {
            const current_file = file.? orelse unreachable;
            if (@backingInt(current_file) + char - '0' > 8)
                return failFenParsing(error_offset, offset, FenError.TooManyFiles);

            file = current_file.step(@intCast(char - '0'));
        },
        else => {
            if (!file)
                return failFenParsing(error_offset, offset, FenError.TooManyFiles);

            const piece = charToPiece(char) orelse
                return failFenParsing(error_offset, offset, FenError.InvalidPiece);
            position.placePiece(piece, .fromCoords(file, rank));

            file = file.?.step(File.east) orelse unreachable;
        },
    };
    if (rank != .@"1")
        return failFenParsing(error_offset, fields.index, FenError.TooFewRanks);
    if (file)
        return failFenParsing(error_offset, fields.index, FenError.TooFewFiles);

    // 2. Side to move.
    const side = fields.next() orelse
        return failFenParsing(error_offset, input.len, FenError.MissingSideToMove);

    position.side_to_move = if (std.mem.eql(u8, side, "w"))
        .white
    else if (std.mem.eql(u8, side, "b"))
        .black
    else
        return failFenParsing(error_offset, fields.index - side.len, FenError.InvalidSideToMove);

    // 3. Castling rights: KQkq (X-FEN) or Shredder-FEN file letters.
    const castling = fields.next() orelse
        return failFenParsing(error_offset, input.len, FenError.MissingCastling);

    if (!std.mem.eql(u8, castling, "-")) {
        for (castling, fields.index - castling.len..) |char, offset| {
            const color: Color = if (std.ascii.isLower(char)) .black else .white;
            const rook: Piece = .create(color, .rook);

            const king_square = position.kingSquare(color);
            const rook_square: Square = switch (std.ascii.toLower(char)) {
                'k' => Square.h1.relative(color),
                'q' => Square.a1.relative(color),
                'a'...'h' => |lower| .fromCoords(.fromChar(lower), .@"1"),
                else => null,
            } orelse return failFenParsing(error_offset, offset, FenError.InvalidCastling);

            switch (std.ascii.toLower(char)) {
                'k' => {
                    if (king_square != Square.e1.relative(color) or @backingInt(rook_square.file()) <= @backingInt(File.e))
                        return failFenParsing(error_offset, offset, FenError.InvalidCastling);
                },
                'q' => {
                    if (king_square != Square.e1.relative(color) or @backingInt(rook_square.file() >= @backingInt(File.e)))
                        return failFenParsing(error_offset, offset, FenError.InvalidCastling);
                },
                else => {
                    position.chess960 = true;
                },
            }

            if (position.onSquare(rook_square).? != rook)
                return failFenParsing(error_offset, offset, FenError.InvalidCastling);

            position.addCastlingRight(color, king_square, rook_square);
        }
    }

    // 4. En passant square.
    const en_passant = fields.next() orelse
        return failFenParsing(error_offset, input.len, FenError.MissingEnPassant);

    if (!std.mem.eql(u8, en_passant, "-")) {
        const en_passant_start = fields.index - en_passant.len;

        if (en_passant.len != 2 or en_passant[0] < 'a' or en_passant[0] > 'h')
            return failFenParsing(error_offset, en_passant_start, FenError.InvalidEnPassant);

        // The target square lies behind the pawn that just double-pushed.
        const expected_rank: u8 = if (position.side_to_move == .white) '6' else '3';
        if (en_passant[1] != expected_rank)
            return failFenParsing(error_offset, en_passant_start + 1, FenError.InvalidEnPassant);

        state.en_passant_square = .fromCoords(.fromChar(en_passant[0]), .fromChar(expected_rank));
    }

    // 5. Halfmove clock.
    const halfmove = fields.next() orelse
        return failFenParsing(error_offset, input.len, FenError.MissingHalfmoveClock);
    state.halfmove_clock = try std.fmt.parseUnsigned(usize, halfmove, 10) catch
        failFenParsing(error_offset, fields.index - halfmove.len, FenError.InvalidHalfmoveClock);

    if (state.halfmove_clock > 75)
        failFenParsing(error_offset, fields.index - halfmove.len, FenError.InvalidHalfmoveClock);

    // 6. Fullmove number (starts at 1).
    const fullmove = fields.next() orelse
        return failFenParsing(error_offset, input.len, FenError.MissingFullmoveNumber);
    const fullmove_number = std.fmt.parseUnsigned(usize, fullmove, 10) catch
        failFenParsing(error_offset, fields.index - fullmove.len, FenError.InvalidFullmoveNumber);

    if (fullmove_number == 0 or fullmove_number > 8848)
        return failFenParsing(error_offset, fields.index - 1, FenError.InvalidFullmoveNumber);

    position.game_ply = 2 * (fullmove - 1) + @intFromBool(position.side_to_move == .black);

    // TODO: compute zobrist_key, checkers, blockers.
    // TODO: optimize parsing by writing custom tokenizer.

    return fields.rest();
}

pub fn setStartPosition(position: *Position, state: *State) void {
    _ = setFen(position, state, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", null) catch unreachable;
}

pub fn setKiwipetePosition(position: *Position, state: *State) void {
    _ = setFen(position, state, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
}

pub fn writeFen(position: *const Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // 1. Piece placement, rank 8 down to rank 1.
    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        if (rank != .@"8") try writer.writeByte('/');

        var empty: u8 = 0;
        for (std.enums.values(File)) |file| {
            if (position.onSquare(.fromCoords(file, rank))) |piece| {
                if (empty > 0) {
                    try writer.writeByte('0' + empty);
                    empty = 0;
                }
                try writer.writeByte(piece.toChar());
            } else {
                empty += 1;
            }
        }
        if (empty > 0) try writer.writeByte('0' + empty);
    }

    // 2. Side to move.
    try writer.writeAll(if (position.side_to_move == .white) " w " else " b ");

    // 3. Castling rights: KQkq, or Shredder-FEN file letters in Chess960.
    const castling = position.state.castling_rights;
    var any_castling = false;
    inline for (.{
        .{ "white_00", 'K' },
        .{ "white_000", 'Q' },
        .{ "black_00", 'k' },
        .{ "black_000", 'q' },
    }) |entry| {
        if (@field(castling, entry[0]) == 1) {
            any_castling = true;

            if (position.chess960) {
                var single: Castling = .none;
                @field(single, entry[0]) = 1;
                const index: usize = @as(u4, @bitCast(single));
                const file_char = @tagName(position.castling_rook_square[index].file())[0];
                try writer.writeByte(if (std.ascii.isUpper(entry[1])) std.ascii.toUpper(file_char) else file_char);
            } else {
                try writer.writeByte(entry[1]);
            }
        }
    }
    try writer.writeAll(if (any_castling) " " else "- ");

    // 4. En passant square.
    if (position.state.en_passant_square) |sq| {
        try writer.print("{s}{s} ", .{ @tagName(sq.file()), @tagName(sq.rank()) });
    } else {
        try writer.writeAll("- ");
    }

    // 5/6. Halfmove clock and fullmove number.
    try writer.print("{d} {d}", .{ position.state.halfmove_clock, position.game_ply / 2 + 1 });
}

pub fn format(position: *const Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const separator = "+---+---+---+---+---+---+---+---+\n";

    try writer.writeAll(separator);

    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        for (std.enums.values(File)) |file| {
            const piece = position.onSquare(.fromCoords(file, rank));
            try writer.print("| {c} ", .{if (piece) |p| p.toChar() else ' '});
        }

        try writer.print("| {s}\n" ++ separator, .{@tagName(rank)});
    }

    try writer.writeAll("  a   b   c   d   e   f   g   h\nFEN: ");
    try position.writeFen(writer);
    try writer.print("\nZobrist Hash: 0x{x:0>16}\n", .{position.state.zobrist_key});
}
