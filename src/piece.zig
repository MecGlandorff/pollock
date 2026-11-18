const std = @import("std");

const Color = @import("pollock").Color;

pub const Piece = packed struct(u4) {
    color: Color,
    type: Type,

    pub const Type = enum(u3) {
        pawn = 0,
        knight,
        bishop,
        rook,
        queen,
        king,
    };

    pub const AttackType = enum(u3) {
        white_pawn = 0,
        knight,
        bishop,
        rook,
        queen,
        king,
        black_pawn = 6,
    };

    pub const white_pawn = create(.white, .pawn);
    pub const white_knight = create(.white, .knight);
    pub const white_bishop = create(.white, .bishop);
    pub const white_rook = create(.white, .rook);
    pub const white_queen = create(.white, .queen);
    pub const white_king = create(.white, .king);
    pub const black_pawn = create(.black, .pawn);
    pub const black_knight = create(.black, .knight);
    pub const black_bishop = create(.black, .bishop);
    pub const black_rook = create(.black, .rook);
    pub const black_queen = create(.black, .queen);
    pub const black_king = create(.black, .king);

    pub const count = 12;

    /// Creates a new piece.
    pub inline fn create(color: Color, @"type": Type) Piece {
        return .{ .color = color, .type = @"type" };
    }

    /// Switches the color of `piece`.
    pub inline fn opposite(piece: Piece) Piece {
        return .{ .color = piece.color.opposite(), .type = piece.type };
    }

    /// Returns `piece` as a character.
    pub fn toChar(piece: Piece) u8 {
        const character: [count]u8 = .{ 'P', 'p', 'N', 'n', 'B', 'b', 'R', 'r', 'Q', 'q', 'K', 'k' };

        return character[@backingInt(piece)];
    }
};
