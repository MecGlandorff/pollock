const std = @import("std");

const pollock = @import("pollock");
const Bitboard = pollock.Bitboard;
const Castling = pollock.Castling;
const Color = pollock.Color;
const Piece = pollock.Piece;
const Rank = pollock.Rank;
const File = pollock.File;
const Square = pollock.Square;
const ZobristKey = pollock.ZobristKey;

const Position = @This();

board: std.EnumArray(Square, ?Piece),
type_occupancy: std.EnumArray(Piece.Type, Bitboard),
color_occupancy: std.EnumArray(Color, Bitboard),

info: *Info,

castling_mask: std.EnumArray(Square, Castling),
castling_rook_square: [Castling.count]Square,
castling_path: [Castling.count]Bitboard,
game_ply: usize,
side_to_move: Color,
chess960: bool,

pub const Info = struct {
    castling_rights: Castling,
    en_passant_square: ?Square,
    halfmove_clock: usize,

    previous_info: ?*const Info,
    zobrist_key: ZobristKey,
    checkers: Bitboard,
    blockers: std.EnumArray(Color, Bitboard),
    captured_piece: ?Piece,
    repetition: u32,
};

pub fn kingSquare(position: *const Position, color: Color) Square {
    return @fromBackingInt(@intCast(@ctz(position.pieceOccupancy(color, .king))));
}

pub fn colorOccupancy(position: *const Position, color: Color) Bitboard {
    return position.color_occupancy.get(color);
}

pub fn pieceOccupancy(position: *const Position, color: Color, piece_type: Piece.Type) Bitboard {
    return position.colorOccupancy(color).@"and"(position.type_occupancy.get(piece_type));
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

pub const FenDiagnostics = struct {
    /// Byte offset into the FEN where parsing failed.
    offset: usize = 0,
};

const Tokens = std.mem.TokenIterator(u8, .any);

fn fail(diagnostics: ?*FenDiagnostics, offset: usize, err: FenError) FenError {
    if (diagnostics) |d| d.offset = offset;
    return err;
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

/// Consumes the next token only if it is purely numeric, so trailing text
/// such as "moves ..." stays in the remainder.
fn number(
    fields: *Tokens,
    input_len: usize,
    diagnostics: ?*FenDiagnostics,
    missing: FenError,
    invalid: FenError,
) FenError!usize {
    const token = fields.next() orelse return fail(diagnostics, input_len, missing);
    return std.fmt.parseUnsigned(usize, token, 10) catch
        fail(diagnostics, fields.index - token.len, invalid);
}

fn square(file: usize, rank: usize) Square {
    return .fromCoords(@fromBackingInt(@intCast(file)), @fromBackingInt(@intCast(rank)));
}

/// Squares on `rank` from file `a` to file `b`, both inclusive, in either order.
fn span(rank: Rank, a: usize, b: usize) Bitboard {
    var bb: Bitboard = .empty;
    for (@min(a, b)..@max(a, b) + 1) |file| {
        bb = bb.@"or"(square(file, @backingInt(rank)).bitboard());
    }
    return bb;
}

fn orRights(a: Castling, b: Castling) Castling {
    return @bitCast(@as(u4, @bitCast(a)) | @as(u4, @bitCast(b))); // assumed: Castling is packed struct(u4)
}

/// File of the first `piece` found on `rank`.
fn findOnRank(position: *const Position, rank: Rank, piece: Piece) ?usize {
    for (0..8) |file| if (position.board.get(square(file, @backingInt(rank))) == piece) return file;
    return null;
}

/// X-FEN rule: the outermost rook of the right colour on the king's side.
fn findOuterRook(position: *const Position, rank: Rank, rook: Piece, king_file: usize, kingside: bool) ?usize {
    if (kingside) {
        var file: usize = 7;
        while (file > king_file) : (file -= 1)
            if (position.board.get(square(file, @backingInt(rank))) == rook) return file;
    } else {
        for (0..king_file) |file|
            if (position.board.get(square(file, @backingInt(rank))) == rook) return file;
    }
    return null;
}

/// Mirrors Stockfish's set_castling_right.
fn addCastlingRight(position: *Position, color: Color, king_file: usize, rook_file: usize) void {
    const rank: Rank = if (color == .white) .@"1" else .@"8";
    const kingside = rook_file > king_file;

    var right: Castling = .none;
    switch (color) {
        .white => if (kingside) {
            right.white_00 = 1;
        } else {
            right.white_000 = 1;
        },
        .black => if (kingside) {
            right.black_00 = 1;
        } else {
            right.black_000 = 1;
        },
    }

    const king_from = square(king_file, @backingInt(rank));
    const rook_from = square(rook_file, @backingInt(rank));
    const king_to: usize = if (kingside) 6 else 2; // g or c file
    const rook_to: usize = if (kingside) 5 else 3; // f or d file

    position.info.castling_rights = orRights(position.info.castling_rights, right);
    for ([_]Square{ king_from, rook_from }) |sq|
        position.castling_mask.set(sq, orRights(position.castling_mask.get(sq), right));

    // assumed: indexed by the right's bitmask like Stockfish, i.e. Castling.count == 16.
    const index: usize = @as(u4, @bitCast(right));
    position.castling_rook_square[index] = rook_from;
    const path = span(rank, rook_file, rook_to).@"or"(span(rank, king_file, king_to));
    const origins = king_from.bitboard().@"or"(rook_from.bitboard());
    position.castling_path[index] = path.@"and"(origins.not());

    // Anything other than the classical king/rook files needs Chess960 move handling.
    if (king_file != 4 or (rook_file != 0 and rook_file != 7)) position.chess960 = true;
}

pub fn placePiece(position: *Position, piece: Piece, sq: Square) void {
    std.debug.assert(position.board.get(sq) == null);

    const bb = sq.bitboard();
    position.board.set(sq, piece);
    position.type_occupancy.getPtr(piece.type).bits |= bb.bits;
    position.color_occupancy.getPtr(piece.color).bits |= bb.bits;
}

/// Parses a FEN from the start of `input` and returns the unconsumed rest
/// (leading whitespace removed), e.g. "moves e2e4 e7e5".
/// On error, `position` is left in an unspecified (partially filled) state.
pub fn setFen(
    position: *Position,
    info: *Info,
    input: []const u8,
    diagnostics: ?*FenDiagnostics,
) FenError![]const u8 {
    info.* = .{
        .castling_rights = .none,
        .en_passant_square = null,
        .halfmove_clock = 0,
        .previous_info = null,
        .zobrist_key = 0,
        .checkers = .empty,
        .blockers = .initFill(.empty),
        .captured_piece = null,
        .repetition = 0,
    };

    position.* = .{
        .board = .initFill(null),
        .type_occupancy = .initFill(.empty),
        .color_occupancy = .initFill(.empty),
        .info = info,
        .castling_mask = .initFill(.none),
        .castling_rook_square = undefined,
        .castling_path = @splat(.empty),
        .side_to_move = undefined,
        .game_ply = 0,
        .chess960 = false,
    };

    // After next(), `fields.index` is just past the returned token, so
    // `fields.index - token.len` is the token's start offset.
    var fields = std.mem.tokenizeAny(u8, input, " \t");

    // 1. Piece placement.
    const placement = fields.next() orelse
        return fail(diagnostics, input.len, FenError.MissingPiecePlacement);
    const placement_start = fields.index - placement.len;

    var rank: usize = 7; // Number of ranks left to go.
    var file: usize = 0; // Number of squares filled on the current rank.
    for (placement, placement_start..) |char, offset| switch (char) {
        '/' => {
            if (file < 8)
                return fail(diagnostics, offset, FenError.TooFewFiles);
            if (rank == 0)
                return fail(diagnostics, offset, FenError.TooManyRanks);

            rank -= 1;
            file = 0;
        },
        '1'...'8' => {
            file += char - '0';

            if (file > 8)
                return fail(diagnostics, offset, FenError.TooManyFiles);
        },
        else => {
            if (file >= 8)
                return fail(diagnostics, offset, FenError.TooManyFiles);

            const piece = charToPiece(char) orelse
                return fail(diagnostics, offset, FenError.InvalidPiece);
            position.placePiece(piece, square(file, rank));

            file += 1;
        },
    };
    if (rank > 0)
        return fail(diagnostics, fields.index, FenError.TooFewRanks);
    if (file < 8)
        return fail(diagnostics, fields.index, FenError.TooFewFiles);

    // 2. Side to move.
    const side = fields.next() orelse
        return fail(diagnostics, input.len, FenError.MissingSideToMove);

    position.side_to_move = if (std.mem.eql(u8, side, "w"))
        .white
    else if (std.mem.eql(u8, side, "b"))
        .black
    else
        return fail(diagnostics, fields.index - side.len, FenError.InvalidSideToMove);

    // 3. Castling rights: KQkq (X-FEN) or Shredder-FEN file letters.
    const castling = fields.next() orelse
        return fail(diagnostics, input.len, FenError.MissingCastling);

    if (!std.mem.eql(u8, castling, "-")) {
        for (castling, fields.index - castling.len..) |char, offset| {
            const color: Color = if (std.ascii.isLower(char)) .black else .white;
            const back_rank: Rank = if (color == .white) .@"1" else .@"8";
            const own_king: Piece = if (color == .white) .white_king else .black_king;
            const own_rook: Piece = if (color == .white) .white_rook else .black_rook;

            const king_file = findOnRank(position, back_rank, own_king) orelse
                return fail(diagnostics, offset, FenError.InvalidCastling);

            const rook_file: usize = switch (std.ascii.toUpper(char)) {
                'K' => findOuterRook(position, back_rank, own_rook, king_file, true),
                'Q' => findOuterRook(position, back_rank, own_rook, king_file, false),
                'A'...'H' => |upper| blk: {
                    const rook_file: usize = upper - 'A';
                    const valid = rook_file != king_file and position.board.get(square(rook_file, @backingInt(back_rank))) == own_rook;

                    break :blk if (valid) rook_file else null;
                },
                else => null,
            } orelse return fail(diagnostics, offset, FenError.InvalidCastling);

            addCastlingRight(position, color, king_file, rook_file);
        }
    }

    // 4. En passant square.
    const en_passant = fields.next() orelse
        return fail(diagnostics, input.len, FenError.MissingEnPassant);

    if (!std.mem.eql(u8, en_passant, "-")) {
        const en_passant_start = fields.index - en_passant.len;

        if (en_passant.len != 2 or en_passant[0] < 'a' or en_passant[0] > 'h')
            return fail(diagnostics, en_passant_start, FenError.InvalidEnPassant);

        // The target square lies behind the pawn that just double-pushed.
        const expected_rank: u8 = if (position.side_to_move == .white) '6' else '3';
        if (en_passant[1] != expected_rank)
            return fail(diagnostics, en_passant_start + 1, FenError.InvalidEnPassant);

        info.en_passant_square = .fromCoords(.fromChar(en_passant[0]), .fromChar(expected_rank));
    }

    // 5. Halfmove clock.
    info.halfmove_clock = try number(
        &fields,
        input.len,
        diagnostics,
        FenError.MissingHalfmoveClock,
        FenError.InvalidHalfmoveClock,
    );

    // 6. Fullmove number (starts at 1).
    const fullmove = try number(
        &fields,
        input.len,
        diagnostics,
        FenError.MissingFullmoveNumber,
        FenError.InvalidFullmoveNumber,
    );
    const max_fullmove = std.math.maxInt(usize) / 2 + 1;
    if (fullmove == 0 or fullmove > max_fullmove)
        return fail(diagnostics, fields.index - 1, FenError.InvalidFullmoveNumber);

    position.game_ply = 2 * (fullmove - 1) + @intFromBool(position.side_to_move == .black);

    // TODO: compute zobrist_key, checkers, blockers, repetition.

    return fields.rest();
}

pub fn setStartPosition(position: *Position, info: *Info) void {
    _ = setFen(position, info, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", null) catch unreachable;
}

pub fn setKiwipetePosition(position: *Position, info: *Info) void {
    _ = setFen(position, info, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
}

pub fn writeFen(position: *const Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // 1. Piece placement, rank 8 down to rank 1.
    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        if (rank != .@"8") try writer.writeByte('/');

        var empty: u8 = 0;
        for (std.enums.values(File)) |file| {
            if (position.board.get(.fromCoords(file, rank))) |piece| {
                if (empty > 0) {
                    try writer.writeByte('0' + empty);
                    empty = 0;
                }
                try writer.writeByte(piece.toChar()); // assumed: Piece.toChar() u8
            } else {
                empty += 1;
            }
        }
        if (empty > 0) try writer.writeByte('0' + empty);
    }

    // 2. Side to move.
    try writer.writeAll(if (position.side_to_move == .white) " w " else " b ");

    // 3. Castling rights: KQkq, or Shredder-FEN file letters in Chess960.
    const castling = position.info.castling_rights;
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
                const index: usize = @as(u4, @bitCast(single)); // assumed: same indexing as fromFen
                const file_char = @tagName(position.castling_rook_square[index].file())[0]; // assumed: Square.file()
                try writer.writeByte(if (std.ascii.isUpper(entry[1])) std.ascii.toUpper(file_char) else file_char);
            } else {
                try writer.writeByte(entry[1]);
            }
        }
    }
    try writer.writeAll(if (any_castling) " " else "- ");

    // 4. En passant square.
    if (position.info.en_passant_square) |sq| {
        try writer.print("{s}{s} ", .{ @tagName(sq.file()), @tagName(sq.rank()) }); // assumed: Square.rank()
    } else {
        try writer.writeAll("- ");
    }

    // 5/6. Halfmove clock and fullmove number.
    try writer.print("{d} {d}", .{ position.info.halfmove_clock, position.game_ply / 2 + 1 });
}

pub fn format(position: *const Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const separator = "+---+---+---+---+---+---+---+---+\n";

    try writer.writeAll(separator);

    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        for (std.enums.values(File)) |file| {
            const piece = position.board.get(.fromCoords(file, rank));
            try writer.print("| {c} ", .{if (piece) |p| p.toChar() else ' '});
        }

        try writer.print("| {s}\n" ++ separator, .{@tagName(rank)});
    }

    try writer.writeAll("  a   b   c   d   e   f   g   h\nFEN: ");
    try position.writeFen(writer);
    try writer.print("\nZobrist Hash: 0x{x:0>16}\n", .{position.info.zobrist_key});
}
