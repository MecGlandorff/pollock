const std = @import("std");

const pollock = @import("pollock");
const Piece = pollock.Piece;
const Square = pollock.Square;

/// A move packed into 16 bits:
///
///     Bits 0-5:   destination square,
///     Bits 6-11:  source square,
///     Bits 12-13: move type,
///     Bits 14-15: promotion piece type (knight to queen).
///
/// Castling is encoded as the king moving onto its own rook (source is the king square, destination is the rook
/// square), in both standard and Chess960 mode. `print` converts it to the king's two-square move in standard mode.
pub const Move = packed struct(u16) {
    destination: Square = .a1,
    source: Square = .a1,
    kind: Kind = .normal,
    /// Only meaningful for promotions, otherwise always `.knight` so equal moves compare equal.
    promotion_piece: Promotion = .knight,

    /// Upper bound on the number of legal moves in any position, used to size move lists.
    pub const max_moves = 256;

    /// The null move, with source equal to destination. No legal move looks like this.
    pub const null_move: Move = .{};

    pub const Kind = enum(u2) {
        normal = 0,
        promotion,
        castle,
        en_passant,
    };

    pub const Promotion = enum(u2) {
        knight = 0,
        bishop,
        rook,
        queen,
    };

    /// Returns whether `move` is the null move.
    pub inline fn isNull(move: Move) bool {
        return move.source == move.destination;
    }

    /// Creates a move from `source` to `destination` with `kind` and `promotion_piece`.
    pub inline fn create(source: Square, destination: Square, kind: Kind, promotion_piece: Promotion) Move {
        std.debug.assert(source != destination);

        return .{
            .source = source,
            .destination = destination,
            .kind = kind,
            .promotion_piece = promotion_piece,
        };
    }

    /// Creates a normal move from `source` to `destination`.
    pub inline fn normal(source: Square, destination: Square) Move {
        return create(source, destination, .normal, .knight);
    }

    /// Creates an en passant capture from `source` to `destination`.
    pub inline fn enPassant(source: Square, destination: Square) Move {
        return create(source, destination, .en_passant, .knight);
    }

    /// Creates a castle move as the king on `king_square` moving onto its castling rook on `rook_square`.
    pub inline fn castle(king_square: Square, rook_square: Square) Move {
        return create(king_square, rook_square, .castle, .knight);
    }

    /// Creates a promotion from `source` to `destination` into `promotion_piece`.
    pub inline fn promotion(source: Square, destination: Square, promotion_piece: Promotion) Move {
        return create(source, destination, .promotion, promotion_piece);
    }

    /// Returns the piece type that `move` promotes to. Only valid for promotions.
    pub inline fn promotionType(move: Move) Piece.Type {
        return @fromBackingInt(@as(Piece.Type.TypeInt, @backingInt(move.promotion_piece)) + 1);
    }

    /// Returns the UCI character of the promotion piece (`n`, `b`, `r`, `q`). Only valid for promotions.
    pub inline fn promotionChar(move: Move) u8 {
        return switch (move.promotion_piece) {
            .knight => 'n',
            .bishop => 'b',
            .rook => 'r',
            .queen => 'q',
        };
    }

    /// Writes `move` in UCI notation. Castling is written as the king capturing its own rook if `chess960` is set,
    /// otherwise as the king moving two squares.
    pub fn print(move: Move, chess960: bool, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        std.debug.assert(!move.isNull());

        const source = move.source;
        const destination: Square = if (move.kind == .castle and !chess960)
            .fromCoords(if (source.less(move.destination)) .g else .c, source.rank())
        else
            move.destination;

        try writer.print("{s}{s}", .{ @tagName(source), @tagName(destination) });

        if (move.kind == .promotion)
            try writer.writeByte(move.promotionChar());
    }
};
