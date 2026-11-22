const std = @import("std");

const Color = @import("pollock").Color;

/// A colored piece, packed into 4 bits: the color is bit 0 and the type is bits 1-3. `index` therefore runs 0-11 in
/// the order white pawn, black pawn, white knight, black knight, and so on.
pub const Piece = packed struct(u4) {
    color: Color,
    type: Type,

    /// The type of a piece, regardless of color.
    pub const Type = enum(u3) {
        pawn = 0,
        knight,
        bishop,
        rook,
        queen,
        king,

        pub const TypeInt = std.meta.Tag(Type);
    };

    /// Selects an attack table. Unlike `Type`, pawns are split by color, because their attacks depend on direction.
    pub const AttackType = enum(u3) {
        white_pawn = 0,
        knight,
        bishop,
        rook,
        queen,
        king,
        black_pawn = 6,

        const AttackTypeInt = std.meta.Tag(AttackType);

        /// Returns the attack type of a pawn of `color` itself (`white_pawn` for white, `black_pawn` for black).
        pub fn forPawn(color: Color) AttackType {
            return @fromBackingInt(@as(AttackTypeInt, @backingInt(color)) * @backingInt(AttackType.black_pawn));
        }
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

    /// Number of distinct pieces, which is also the exclusive upper bound of `index`.
    pub const count = 12;

    /// Creates a piece of `color` and `type`.
    pub inline fn create(color: Color, @"type": Type) Piece {
        return .{ .color = color, .type = @"type" };
    }

    /// Returns the piece for the FEN character `char` (uppercase is white), or `null` if there is none.
    pub fn fromChar(char: u8) ?Piece {
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

    /// Returns the piece of the same type as `piece` with the opposite color.
    pub inline fn flipColor(piece: Piece) Piece {
        return .{ .color = piece.color.opposite(), .type = piece.type };
    }

    /// Returns the FEN character of `piece`.
    pub inline fn toChar(piece: Piece) u8 {
        return "PpNnBbRrQqKk"[piece.index()];
    }

    /// Returns `piece` as an index below `count`, e.g. for Zobrist keys.
    pub inline fn index(piece: Piece) usize {
        return @backingInt(piece);
    }
};
