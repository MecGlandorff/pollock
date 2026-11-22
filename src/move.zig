const std = @import("std");

const pollock = @import("pollock");
const Castling = pollock.Castling;
const Color = pollock.Color;
const Piece = pollock.Piece;
const Position = pollock.Position;
const Square = pollock.Square;

/// A move packed into 16 bits:
///
///     Bits 0-5:   source square,
///     Bits 6-11:  destination square,
///     Bits 12-13: move type,
///     Bits 14-15: promotion piece type (knight to queen).
///
/// Castling is encoded as the king moving onto its own rook (the source is the king square, the destination is the
/// rook square) in Chess960 mode, and onto g1/c1 (relative to the color) otherwise.
pub const Move = packed struct(u16) {
    source: Square = .a1,
    destination: Square = .a1,
    move_type: Type = .normal,
    /// Only meaningful for promotions, otherwise always `.knight` so equal moves compare equal.
    promotion: Promotion = .knight,

    /// Upper bound on the number of legal moves in any position, used to size move lists.
    pub const max_moves = 256;

    /// The null move, with source equal to destination. No legal move looks like this.
    pub const null_move: Move = .{};

    pub const Type = enum(u2) {
        normal = 0,
        promotion,
        castle,
        en_passant,
    };

    const Promotion = enum(u2) {
        knight = 0,
        bishop,
        rook,
        queen,
    };

    /// Returns whether the source of `move` equals its destination, which should only be the case for the null move.
    pub inline fn isNull(move: Move) bool {
        return move.source == move.destination;
    }

    /// Creates a move from `source` to `destination` with `move_type` and `promotion`.
    pub inline fn create(source: Square, destination: Square, move_type: Type, promotion: Promotion) Move {
        std.debug.assert(source != destination);

        return .{
            .source = source,
            .destination = destination,
            .move_type = move_type,
            .promotion = promotion,
        };
    }

    /// Creates a normal move from `source` to `destination`.
    pub inline fn createNormal(source: Square, destination: Square) Move {
        return create(source, destination, .normal, .knight);
    }

    /// Creates an en passant capture from `source` to `destination`.
    pub inline fn createEnPassant(source: Square, destination: Square) Move {
        return create(source, destination, .en_passant, .knight);
    }

    /// Creates a castle move for `color` in `position`. Castling must be possible, and `side` must be either
    /// `Castling.kingside` or `Castling.queenside`.
    pub fn createCastle(position: *const Position, color: Color, side: Castling) Move {
        std.debug.assert(side == Castling.kingside or side == Castling.queenside);

        const kingside = side == Castling.kingside;
        const destination: Square = if (position.chess960)
            position.castlingRookSquare(.right(color, kingside))
        else
            .relative(if (kingside) .g1 else .c1, color);

        return .create(position.kingSquare(color), destination, .castle, .knight);
    }

    /// Returns the piece type that `move` promotes to. Only valid for promotions.
    pub inline fn promotionPieceType(move: Move) Piece.Type {
        return @fromBackingInt(@as(Piece.Type.TypeInt, @backingInt(move.promotion)) + 1);
    }

    /// Returns the character of the promotion piece of `move` in UCI notation (`n`, `b`, `r`, `q`).
    pub inline fn promotionChar(move: Move) u8 {
        return switch (move.promotion) {
            .knight => 'n',
            .bishop => 'b',
            .rook => 'r',
            .queen => 'q',
        };
    }
};
