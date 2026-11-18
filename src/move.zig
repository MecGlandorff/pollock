const std = @import("std");

const pollock = @import("pollock");
const Castling = pollock.Castling;
const Color = pollock.Color;
const Piece = pollock.Piece;
const Square = pollock.Square;

pub const Move = packed struct(u16) {
    // We use 16 bits to describe a move. We need 6 bits for the source square as well as the destination square.
    // The remaining 4 bits are used for special moves:
    //
    //      Bits 0-5: source square (0-63),
    //      Bits 6-11: destination square (0-63),
    //      Bits 12-13: special bits (normal: 0, promotion: 1, castle: 2, en passant: 3),
    //      Bits 14-15: promotion piece - 1

    source: Square = .a1,
    destination: Square = .a1,
    move_type: Type = .normal,
    promotion: Promotion = .knight,

    pub const max_moves = 256;

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

    /// Returns `true` if `move`s source is equal to its destination and it is not supposed to be.
    pub inline fn isWeird(move: Move) bool {
        return move.source == move.destination and !(pollock.chess960 and move.move_type == .castle);
    }

    /// Creates a move from `source` to `destination` with `move_type` and `promotion`.
    pub inline fn create(source: Square, destination: Square, move_type: Type, promotion: Promotion) Move {
        std.debug.assert(source != destination or (pollock.chess960 and move_type == .castle));

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

    /// Creates a new castle move. Castling must be possible and `castle_side` must
    /// be equal to either `Castling.king_side` or `Castling.queen_side`.
    pub inline fn createCastle(king_square: Square, castle_side: Castling) Move {
        std.debug.assert(castle_side == Castling.king_side or castle_side == Castling.queen_side);

        const square: Square = switch (castle_side) {
            Castling.king_side => .g1,
            Castling.queen_side => .c1,
            else => unreachable,
        };
        const color: Color = @fromBackingInt(@intFromBool(king_square.rank() != .@"1"));
        const destination: Square = .relative(square, color);

        return .create(king_square, destination, .castle, .knight);
    }

    /// Returns the piece type of the promotion of `move`.
    pub inline fn promotionPieceType(move: Move) Piece.Type {
        return switch (move.promotion) {
            .knight => .knight,
            .bishop => .bishop,
            .rook => .rook,
            .queen => .queen,
        };
    }

    /// Returns the character corresponding the promotion type of `move`.
    pub inline fn promotionChar(move: Move) u8 {
        return switch (move.promotion) {
            .knight => 'n',
            .bishop => 'b',
            .rook => 'r',
            .queen => 'q',
        };
    }
};
