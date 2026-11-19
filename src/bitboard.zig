const std = @import("std");

const pollock = @import("pollock");
const Color = pollock.Color;
const File = pollock.File;
const Piece = pollock.Piece;
const Square = pollock.Square;

pub const Bitboard = u64;
pub const empty: Bitboard = 0;

const base_attacks: std.EnumArray(Piece.AttackType, std.EnumArray(Square, Bitboard)) = blk: {
    var attacks: std.EnumArray(Piece.AttackType, std.EnumArray(Square, Bitboard)) = .initFill(.initUndefined());

    for (std.enums.values(Square)) |square| {
        attacks.getPtr(.white_pawn).set(square, pawnAttacks(square, .white));
        attacks.getPtr(.black_pawn).set(square, pawnAttacks(square, .black));
        attacks.getPtr(.knight).set(square, nonSliderAttacks(.knight, square));
        attacks.getPtr(.king).set(square, nonSliderAttacks(.king, square));

        const bishop_attacks = sliderAttacks(.bishop, square);
        const rook_attacks = sliderAttacks(.rook, square);

        attacks.getPtr(.bishop).set(square, bishop_attacks);
        attacks.getPtr(.rook).set(square, rook_attacks);
        attacks.getPtr(.queen).set(square, bishop_attacks | rook_attacks);
    }

    break :blk attacks;
};

/// Returns a bitboard of the attacks of `piece_type` on `square` on an empty board.
pub fn baseAttacks(comptime piece_type: Piece.AttackType, square: Square) Bitboard {
    return base_attacks.getPtr(piece_type).get(square);
}

/// Comptime function to generate pawn attacks.
fn pawnAttacks(comptime square: Square, comptime color: Color) Bitboard {
    const square_bb = square.bitboard();

    return if (color == .white)
        shift(square_bb, Square.northwest) | shift(square_bb, Square.northeast)
    else
        shift(square_bb, Square.southwest) | shift(square_bb, Square.southeast);
}

/// Comptime function to generate knight and king attacks.
fn nonSliderAttacks(comptime attack_type: Piece.AttackType, comptime square: Square) Bitboard {
    std.debug.assert(attack_type == .knight or attack_type == .king);

    const knight_steps = [_]Square.Step{
        Square.north + Square.northwest,
        Square.north + Square.northeast,
        Square.east + Square.northeast,
        Square.east + Square.southeast,
        Square.south + Square.southeast,
        Square.south + Square.southwest,
        Square.west + Square.southwest,
        Square.west + Square.northwest,
    };
    const king_steps = [_]Square.Step{
        Square.north,
        Square.northeast,
        Square.east,
        Square.southeast,
        Square.south,
        Square.southwest,
        Square.west,
        Square.northwest,
    };
    const steps = if (attack_type == .knight) knight_steps else king_steps;

    var attacks = empty;
    inline for (steps) |step|
        attacks |= validStep(square, step);

    return attacks;
}

/// Comptime function to generate slider attacks.
fn sliderAttacks(comptime attack_type: Piece.AttackType, comptime square_bb: Bitboard) Bitboard {
    std.debug.assert(attack_type == .bishop or attack_type == .rook);

    const bishop_steps = [_]Square.Step{ Square.northeast, Square.southeast, Square.southwest, Square.northwest };
    const rook_steps = [_]Square.Step{ Square.north, Square.east, Square.south, Square.west };
    const steps = if (attack_type == .bishop) bishop_steps else rook_steps;

    var attacks = empty;
    inline for (steps) |step| {
        var attack = shift(square_bb, step);

        while (attack != empty) {
            attacks |= attack;
            attack = shift(attack, step);
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

    return empty;
}

const between_bitboards: std.EnumArray(Square, std.EnumArray(Square, Bitboard)) = blk: {
    const bitboards: std.EnumArray(Square, std.EnumArray(Square, Bitboard)) = .initFill(.initUndefined());

    for (std.enums.values(Square)) |square1| {
        const square1_bb = square1.bitboard();

        for (std.enums.values(Square)) |square2| {
            const square2_bb = square2.bitboard();
            var bitboard: Bitboard = empty;

            if (baseAttacks(.bishop, square1) & square2_bb != empty) {
                bitboard = baseAttacks(.bishop, square1) & baseAttacks(.bishop, square2);
            } else if (baseAttacks(.rook, square1) & square2_bb != empty) {
                bitboard = baseAttacks(.rook, square1) & baseAttacks(.rook, square2);
            }

            if (square1.less(square2)) {
                bitboard &= ~(square1_bb - 1) & (square2_bb - 1);
            } else {
                bitboard &= (square1_bb - 1) & ~(square2_bb - 1);
            }

            bitboard |= square2_bb;

            bitboards.getPtr(square1).set(square2, bitboard);
        }
    }

    break :blk bitboards;
};

/// Returns a bitboard of the squares in the semi-open segment between `square1` and `square2` (excluding `square1`,
/// including `square2`). If the squares do not lie on the same file/rank/diagonal/antidiagonal, the function returns a
/// bitboard of `square2`.
pub inline fn between(square1: Square, square2: Square) Bitboard {
    return between_bitboards.getPtr(square1).get(square2);
}

/// Shifts `bitboard` by `step`.
pub inline fn shift(bitboard: Bitboard, comptime step: Square.Step) Bitboard {
    return switch (step) {
        Square.north => bitboard << File.count,
        Square.south => bitboard >> File.count,
        Square.northeast => (bitboard & ~File.h.bitboard()) << File.count + 1,
        Square.southeast => (bitboard & ~File.h.bitboard()) >> File.count - 1,
        Square.northwest => (bitboard & ~File.a.bitboard()) << File.count - 1,
        Square.southwest => (bitboard & ~File.a.bitboard()) >> File.count + 1,
        else => empty,
    };
}
