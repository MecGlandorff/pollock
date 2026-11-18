const std = @import("std");

const pollock = @import("pollock");
const File = pollock.File;
const Piece = pollock.Piece;
const Square = pollock.Square;

bits: Bits,

const Bitboard = @This();
const Bits = u64;
pub const empty: Bitboard = .from(0);

const base_attacks: std.EnumArray(Piece.AttackType, std.EnumArray(Square, Bitboard)) = blk: {
    var attacks: std.EnumArray(Piece.AttackType, std.EnumArray(Square, Bitboard)) = .initUndefined();

    for (std.enums.values(Square)) |square| {
        const square_bb = square.bitboard();

        const white_pawn_attacks = (shift(square_bb, Square.north_east) & ~File.a.bitboard()) | (shift(square_bb, Square.north_west) & ~File.h.bitboard());
        attacks[@backingInt(Piece.Type.pawn)].set(square, white_pawn_attacks);

        const black_pawn_attacks = (shift(square_bb, Square.south_east) & ~File.a.bitboard()) | (shift(square_bb, Square.south_west) & ~File.h.bitboard());
        attacks[Piece.Type.count].set(square, black_pawn_attacks);

        attacks[@backingInt(Piece.Type.knight)].set(square, knightAttacks(square));
        attacks[@backingInt(Piece.Type.king)].set(square, kingAttacks(square));
    }

    break :blk attacks;
};

/// Comptime function to generate pawn attacks.
fn pawnAttacks(comptime square: Square, comptime color: Color) Bitboard {}

/// Comptime function to generate knight attacks.
fn knightAttacks(comptime square: Square) Bitboard {
    const steps = [_]Square.Step{
        Square.north + Square.north_west,
        Square.north + Square.north_east,
        Square.east + Square.north_east,
        Square.east + Square.south_east,
        Square.south + Square.south_east,
        Square.south + Square.south_west,
        Square.west + Square.south_west,
        Square.west + Square.north_west,
    };

    var knight_attacks: Bitboard = 0;
    inline for (steps) |step|
        knight_attacks |= validStep(square, step);

    return knight_attacks;
}

/// Comptime function to generate king attacks.
fn kingAttacks(comptime square: Square) Bitboard {
    const steps = [_]Square.Step{
        Square.north,
        Square.north_east,
        Square.east,
        Square.south_east,
        Square.south,
        Square.south_west,
        Square.west,
        Square.north_west,
    };

    var king_attacks: Bitboard = 0;
    inline for (steps) |step|
        king_attacks |= validStep(square, step);

    return king_attacks;
}

/// Comptime function to verify base attacks. Returns a bitboard of `square` displaced by `step` or an empty bitboard if
/// the displaced square is not a valid attack.
inline fn validStep(comptime square: Square, comptime step: Square.Step) Bitboard {
    const destination = std.enums.fromInt(Square, @as(i32, @backingInt(square)) + step);

    if (destination) |d| {
        const file_distance = @abs(@as(i32, @backingInt(square.file())) - @backingInt(d.file()));
        if (file_distance <= 2)
            return d.bitboard();
    }

    return .empty;
}

/// Returns a bitboard from `bits`.
pub inline fn from(bits: Bits) Bitboard {
    return .{ .bits = bits };
}

/// Shifts `bitboard` by `step`.
pub inline fn shift(bitboard: Bitboard, step: Square.Step) Bitboard {
    return .{ .bits = if (step < 0) bitboard.bits >> @abs(step) else bitboard.bits << step };
}
