const std = @import("std");

const pollock = @import("pollock");
const Color = pollock.Color;
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
        attacks.getPtr(.white_pawn).set(square, pawnAttacks(square, .white));
        attacks.getPtr(.black_pawn).set(square, pawnAttacks(square, .black));
        attacks.getPtr(.knight).set(square, knightAttacks(square));
        attacks.getPtr(.king).set(square, kingAttacks(square));

        const bishop_attacks = bishopAttacks(square);
        const rook_attacks = rookAttacks(square);

        attacks.getPtr(.bishop).set(square, bishop_attacks);
        attacks.getPtr(.rook).set(square, rook_attacks);
        attacks.getPtr(.queen).set(square, bishop_attacks.@"or"(rook_attacks));
    }

    break :blk attacks;
};

/// Comptime function to generate pawn attacks.
fn pawnAttacks(comptime square: Square, comptime color: Color) Bitboard {
    const square_bb = square.bitboard();

    return if (color == .white)
        square_bb.shift(Square.northwest).@"or"(square_bb.shift(Square.northeast))
    else
        square_bb.shift(Square.southwest).@"or"(square_bb.shift(Square.southeast));
}

/// Comptime function to generate knight attacks.
fn knightAttacks(comptime square: Square) Bitboard {
    const steps = [_]Square.Step{
        Square.north + Square.northwest,
        Square.north + Square.northeast,
        Square.east + Square.northeast,
        Square.east + Square.southeast,
        Square.south + Square.southeast,
        Square.south + Square.southwest,
        Square.west + Square.southwest,
        Square.west + Square.northwest,
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
        Square.northeast,
        Square.east,
        Square.southeast,
        Square.south,
        Square.southwest,
        Square.west,
        Square.northwest,
    };

    var king_attacks: Bitboard = 0;
    inline for (steps) |step|
        king_attacks |= validStep(square, step);

    return king_attacks;
}

/// Comptime function to generate bishop attacks.
fn bishopAttacks(comptime square: Bitboard) Bitboard {
    const directions = [_]Square.Step{ Square.northeast, Square.southeast, Square.southwest, Square.northwest };

    var attacks: Bitboard = .empty;
    for (directions) |step| {
        var attack = square.shift(step);
        while (attack != Bitboard.empty) {
            attacks = attacks.@"or"(attack);
            attack = attack.shift(step);
        }
    }

    return attacks;
}

/// Comptime function to generate rook attacks.
fn rookAttacks(comptime square: Bitboard) Bitboard {
    const directions = [_]Square.Step{ Square.north, Square.east, Square.south, Square.west };

    var attacks: Bitboard = .empty;
    for (directions) |step| {
        var attack = square.shift(step);
        while (attack != Bitboard.empty) {
            attacks = attacks.@"or"(attack);
            attack = attack.shift(step);
        }
    }

    return attacks;
}

/// Comptime function to verify base attacks. Returns a bitboard of `square` displaced by `step` or an empty bitboard if
/// the displaced square is not a valid attack.
inline fn validStep(comptime square: Square, comptime step: i32) Bitboard {
    const destination = std.enums.fromInt(Square, @backingInt(square) + step);

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

/// Shifts `self` by `step`.
pub inline fn shift(self: Bitboard, comptime step: Square.Step) Bitboard {
    return .{ .bits = switch (step) {
        Square.north => self.bits << File.count,
        Square.south => self.bits >> File.count,
        Square.northeast => (self.bits & File.h.bitboard().not()) << File.count + 1,
        Square.southeast => (self.bits & File.h.bitboard().not()) >> File.count - 1,
        Square.northwest => (self.bits & File.a.bitboard().not()) << File.count - 1,
        Square.southwest => (self.bits & File.a.bitboard().not()) >> File.count + 1,
    } };
}

/// Returns the complement of `self`.
pub inline fn not(self: Bitboard) Bitboard {
    return .{ .bits = ~self.bits };
}

/// Returns the union of `self` and `bitboard`.
pub inline fn @"or"(self: Bitboard, bitboard: Bitboard) Bitboard {
    return .{ .bits = self.bits | bitboard.bits };
}

/// Returns the intersection of `self` and `bitboard`.
pub inline fn @"and"(self: Bitboard, bitboard: Bitboard) Bitboard {
    return .{ .bits = self.bits & bitboard.bits };
}
