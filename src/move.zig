const std = @import("std");

const pollock = @import("pollock");
const Castling = pollock.Castling;
const Color = pollock.Color;
const Piece = pollock.Piece;
const Position = pollock.Position;
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

    /// Returns `true` if `move`s source is equal to its destination.
    pub inline fn isWeird(move: Move) bool {
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

    /// Creates a new castle move. Castling must be possible and `side` must be equal to either `Castling.kingside`
    /// or `Castling.queenside`.
    pub fn createCastle(position: *const Position, color: Color, side: Castling) Move {
        std.debug.assert(side == .kingside or side == .queenside);

        var destination: Square = undefined;
        if (position.chess960) {
            const castle: Castling = .right(color, side == .kingside);
            destination = position.castleRookSquare(castle);
        } else {
            destination = .relative(switch (side) {
                Castling.kingside => .g1,
                Castling.queenside => .c1,
                else => unreachable,
            }, color);
        }

        return .create(position.kingSquare(color), destination, .castle, .knight);
    }

    /// Returns the piece type of the promotion of `move`.
    pub inline fn promotionPieceType(move: Move) Piece.Type {
        return @fromBackingInt(@as(u32, @backingInt(move.promotion)) + 1);
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
