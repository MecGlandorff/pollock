const std = @import("std");

const pollock = @import("pollock");
const direction = pollock.direction;
const Direction = direction.Direction;
const Color = pollock.Color;
const File = pollock.File;
const Piece = pollock.Piece;
const Rank = pollock.Rank;
const Square = pollock.Square;

pub const Bitboard = u64;
pub const empty: Bitboard = 0;

/// Comptime function that returns the squares reached by stepping from `square` in `direction1` and `direction2` to
/// the board edge, excluding `square`.
fn lineMask(
    comptime square: Square,
    comptime direction1: Direction,
    comptime direction2: Direction,
) Bitboard {
    var mask: Bitboard = empty;

    inline for (.{ direction1, direction2 }) |d| {
        var destination = validStep(square, d);

        while (destination != empty) {
            mask |= destination;
            destination = shift(destination, d);
        }
    }

    return mask;
}

/// Comptime lookup tables for the geometry between squares.
const Luts = struct {
    /// `[s1][s2]`: the edge-to-edge line through both squares, or empty if they are not aligned.
    line_bitboard: std.EnumArray(Square, std.EnumArray(Square, Bitboard)),
    /// `[s1][s2]`: the squares after `s1` up to and including `s2` (see `between`).
    between_bitboard: std.EnumArray(Square, std.EnumArray(Square, Bitboard)),
    /// `[s]`: the a1-h8 diagonal through `s`, excluding `s`.
    diagonal_bitboard: std.EnumArray(Square, Bitboard),
    /// `[s]`: the a8-h1 diagonal through `s`, excluding `s`.
    antidiagonal_bitboard: std.EnumArray(Square, Bitboard),
};

const luts: Luts = blk: {
    @setEvalBranchQuota(1_000_000);

    var result: Luts = undefined;

    result.line_bitboard = .initFill(.initFill(empty));
    result.between_bitboard = .initFill(.initFill(empty));

    for (std.enums.values(Square)) |square1| {
        const square1_bb = square1.bitboard();

        for ([_]Piece.AttackType{ .bishop, .rook }) |piece_type| {
            for (std.enums.values(Square)) |square2| {
                const square2_bb = square2.bitboard();

                // Aligned squares only. line: the two empty-board attack sets intersect in the line minus the
                // endpoints, so add both. between: each piece attacks the other with only that piece as blocker, which
                // leaves exactly the squares in between.
                if (baseAttacks(piece_type, square1) & square2_bb != empty) {
                    const line_bb = (baseAttacks(piece_type, square1) & baseAttacks(piece_type, square2)) | square1_bb | square2_bb;
                    result.line_bitboard.getPtr(square1).set(square2, line_bb);

                    const between_bb = (attacks(piece_type, square1, square2_bb) & attacks(piece_type, square2, square1_bb));
                    result.between_bitboard.getPtr(square1).set(square2, between_bb);
                }

                // `square2` is included for every pair, aligned or not.
                result.between_bitboard.getPtr(square1).getPtr(square2).* |= square2_bb;
            }
        }

        result.diagonal_bitboard.set(square1, lineMask(square1, direction.southwest, direction.northeast));
        result.antidiagonal_bitboard.set(square1, lineMask(square1, direction.southeast, direction.northwest));
    }

    break :blk result;
};

/// Returns the edge-to-edge line through `square1` and `square2`, or empty if they are not aligned.
pub inline fn line(square1: Square, square2: Square) Bitboard {
    return luts.line_bitboard.getPtrConst(square1).get(square2);
}

/// Returns the squares in the semi-open segment between `square1` and `square2` (excluding `square1`, including
/// `square2`). If the squares do not lie on the same file, rank, diagonal or antidiagonal, returns only `square2`.
pub inline fn between(square1: Square, square2: Square) Bitboard {
    return luts.between_bitboard.getPtrConst(square1).get(square2);
}

/// Returns the a1-h8 diagonal through `square`, excluding `square`.
pub inline fn diagonal(square: Square) Bitboard {
    return luts.diagonal_bitboard.get(square);
}

/// Returns the a8-h1 diagonal through `square`, excluding `square`.
pub inline fn antidiagonal(square: Square) Bitboard {
    return luts.antidiagonal_bitboard.get(square);
}

/// `[attack type][square]`: attacks on an empty board.
const base_attacks: std.EnumArray(Piece.AttackType, std.EnumArray(Square, Bitboard)) = blk: {
    @setEvalBranchQuota(1_000_000);

    var base: std.EnumArray(Piece.AttackType, std.EnumArray(Square, Bitboard)) = .initFill(.initUndefined());

    for (std.enums.values(Square)) |square| {
        base.getPtr(.white_pawn).set(square, pawnAttacks(square, .white));
        base.getPtr(.black_pawn).set(square, pawnAttacks(square, .black));
        base.getPtr(.knight).set(square, nonSliderAttacks(.knight, square));
        base.getPtr(.king).set(square, nonSliderAttacks(.king, square));

        const bishop_attacks = sliderAttacks(.bishop, square, empty);
        const rook_attacks = sliderAttacks(.rook, square, empty);

        base.getPtr(.bishop).set(square, bishop_attacks);
        base.getPtr(.rook).set(square, rook_attacks);
        base.getPtr(.queen).set(square, bishop_attacks | rook_attacks);
    }

    break :blk base;
};

/// Returns the attacks of `piece_type` from `square` on an empty board.
pub fn baseAttacks(piece_type: Piece.AttackType, square: Square) Bitboard {
    return base_attacks.getPtrConst(piece_type).get(square);
}

/// Comptime function that returns the squares attacked by a pawn of `color` on `square`.
fn pawnAttacks(comptime square: Square, comptime color: Color) Bitboard {
    const square_bb = square.bitboard();

    return if (color == .white)
        shift(square_bb, direction.northwest) | shift(square_bb, direction.northeast)
    else
        shift(square_bb, direction.southwest) | shift(square_bb, direction.southeast);
}
/// Comptime function that returns the squares attacked by a knight or king on `square`.
fn nonSliderAttacks(comptime attack_type: Piece.AttackType, comptime square: Square) Bitboard {
    std.debug.assert(attack_type == .knight or attack_type == .king);

    const knight_directions = [_]Direction{
        direction.north + direction.northwest,
        direction.north + direction.northeast,
        direction.east + direction.northeast,
        direction.east + direction.southeast,
        direction.south + direction.southeast,
        direction.south + direction.southwest,
        direction.west + direction.southwest,
        direction.west + direction.northwest,
    };
    const king_directions = [_]Direction{
        direction.north,
        direction.northeast,
        direction.east,
        direction.southeast,
        direction.south,
        direction.southwest,
        direction.west,
        direction.northwest,
    };
    const directions = if (attack_type == .knight) knight_directions else king_directions;

    var attacks_bb = empty;
    inline for (directions) |d|
        attacks_bb |= validStep(square, d);

    return attacks_bb;
}

/// Comptime function that returns the squares attacked by a bishop or rook on `square` given `occupancy`. Rays stop at
/// the first occupied square, which is included.
fn sliderAttacks(
    comptime attack_type: Piece.AttackType,
    comptime square: Square,
    comptime occupancy: Bitboard,
) Bitboard {
    std.debug.assert(attack_type == .bishop or attack_type == .rook);

    const bishop_directions = [_]Direction{
        direction.northeast,
        direction.southeast,
        direction.southwest,
        direction.northwest,
    };
    const rook_directions = [_]Direction{
        direction.north,
        direction.east,
        direction.south,
        direction.west,
    };
    const directions = if (attack_type == .bishop) bishop_directions else rook_directions;

    const square_bb = square.bitboard();
    var attacks_bb = empty;
    inline for (directions) |d| {
        var attack = shift(square_bb, d);

        while (attack != empty) {
            attacks_bb |= attack;

            if (attack & occupancy != empty)
                break;

            attack = shift(attack, d);
        }
    }

    return attacks_bb;
}

/// Comptime function that returns `square` displaced by `step` as a bitboard, or empty if the displacement leaves the
/// board or wraps around its edge. A step moves at most two files, which allows knight steps.
inline fn validStep(comptime square: Square, comptime step: i32) Bitboard {
    const destination = std.enums.fromInt(Square, @backingInt(square) + step);

    if (destination) |d| {
        const file_distance = @abs(@as(i32, @backingInt(square.file())) - @backingInt(d.file()));
        if (file_distance <= 2)
            return d.bitboard();
    }

    return empty;
}

/// Per-square data for sliding attacks. Diagonals, antidiagonals and files use hyperbola quintessence, see
/// https://www.chessprogramming.org/Hyperbola_Quintessence. Ranks use a lookup table of the six inner occupancy bits.
const DualMagic = struct {
    file_mask: Bitboard,
    diagonal_mask: Bitboard,
    antidiagonal_mask: Bitboard,
    no_mask: Bitboard,

    /// Twice the square's bitboard, the `2r` of `o - 2r`.
    r_twice: Bitboard,
    /// The same for the reversed board, used for attacks towards lower squares.
    reversed_r_twice: Bitboard,

    /// Rank attacks of this square's file indexed by the six inner occupancy bits (see `rank_attacks_table`).
    rank_attacks_table: *const [1 << 6]u8,
    /// Index of the first square of this square's rank.
    rank_shift: Square.SquareInt,

    /// Returns the attacks along the line `mask` (which excludes the square itself) given `occupancy`.
    fn hyperbola(
        dual_magic: *const DualMagic,
        mask: Bitboard,
        occupancy: Bitboard,
    ) Bitboard {
        const relevant_occupancy = occupancy & mask;
        const normal = relevant_occupancy -% dual_magic.r_twice;
        const reversed = @byteSwap(@byteSwap(relevant_occupancy) -% dual_magic.reversed_r_twice);

        return (normal ^ reversed) & mask;
    }

    /// Returns the bishop and rook attacks given `occupancy`.
    fn bothAttacks(dual_magic: *const DualMagic, occupancy: Bitboard) struct { Bitboard, Bitboard } {
        const rank_occupancy: u6 = @truncate(occupancy >> (dual_magic.rank_shift + 1));
        const row = dual_magic.rank_attacks_table[rank_occupancy];
        const rank_attacks = @as(Bitboard, row) << dual_magic.rank_shift;

        const bishops = dual_magic.hyperbola(dual_magic.diagonal_mask, occupancy) | dual_magic.hyperbola(dual_magic.antidiagonal_mask, occupancy);
        const rooks = dual_magic.hyperbola(dual_magic.file_mask, occupancy) | rank_attacks;

        return .{ bishops, rooks };
    }
};

/// `[file][occupancy]`: rook attacks along rank 1 from a square on `file`. The occupancy holds only the six inner
/// squares (b-g), since the edge squares never change the attacks.
const rank_attacks_table: std.EnumArray(File, [1 << (File.count - 2)]u8) = blk: {
    @setEvalBranchQuota(1_000_000);

    var table: std.EnumArray(File, [1 << 6]u8) = .initUndefined();

    for (std.enums.values(File)) |file| {
        for (0..1 << 6) |occupancy6| {
            table.getPtr(file)[occupancy6] = @truncate(sliderAttacks(.rook, .fromCoords(file, .@"1"), occupancy6 << 1));
        }
    }

    break :blk table;
};

const dual_magics: std.EnumArray(Square, DualMagic) = blk: {
    @setEvalBranchQuota(1_000_000);

    var array: std.EnumArray(Square, DualMagic) = .initUndefined();

    for (std.enums.values(Square)) |square| {
        const dual_magic: DualMagic = .{
            .file_mask = lineMask(square, direction.south, direction.north),
            .diagonal_mask = lineMask(square, direction.northeast, direction.southwest),
            .antidiagonal_mask = lineMask(square, direction.northwest, direction.southeast),
            .no_mask = 0,
            .r_twice = 2 *% square.bitboard(),
            .reversed_r_twice = 2 *% @byteSwap(square.bitboard()),
            .rank_attacks_table = rank_attacks_table.getPtrConst(square.file()),
            .rank_shift = @as(Square.SquareInt, File.count) * @backingInt(square.rank()),
        };

        array.set(square, dual_magic);
    }

    break :blk array;
};

/// Returns the bishop and rook attacks from `square` given `occupancy`, as a tuple. Computing both at once shares work.
pub inline fn bishopRookAttacks(square: Square, occupancy: Bitboard) struct { Bitboard, Bitboard } {
    return dual_magics.get(square).bothAttacks(occupancy);
}

/// Returns the attacks of `piece_type` from `square` given `occupancy`. Occupancy only matters for sliders.
pub fn attacks(piece_type: Piece.AttackType, square: Square, occupancy: Bitboard) Bitboard {
    const bishop, const rook = bishopRookAttacks(square, occupancy);

    return switch (piece_type) {
        .bishop => bishop,
        .rook => rook,
        .queen => bishop | rook,
        else => baseAttacks(piece_type, square),
    };
}

/// Returns the bitboard of the square at `file` and `rank`.
pub inline fn fromCoords(file: File, rank: Rank) Bitboard {
    return file.bitboard() & rank.bitboard();
}

/// Shifts `bitboard` by `dir`. Bits that would wrap around a board edge are dropped. Other steps return empty.
pub inline fn shift(bitboard: Bitboard, comptime dir: Direction) Bitboard {
    return switch (dir) {
        direction.north => bitboard << File.count,
        direction.south => bitboard >> File.count,
        direction.east => (bitboard & ~File.h.bitboard()) << 1,
        direction.northeast => (bitboard & ~File.h.bitboard()) << File.count + 1,
        direction.southeast => (bitboard & ~File.h.bitboard()) >> File.count - 1,
        direction.west => (bitboard & ~File.a.bitboard()) >> 1,
        direction.northwest => (bitboard & ~File.a.bitboard()) << File.count - 1,
        direction.southwest => (bitboard & ~File.a.bitboard()) >> File.count + 1,
        else => empty,
    };
}

/// Returns the least significant set bit of `bitboard` as a square. Asserts `bitboard != empty`.
pub inline fn lsb(bitboard: Bitboard) Square {
    std.debug.assert(bitboard != empty);

    return @fromBackingInt(@intCast(@ctz(bitboard)));
}

/// Returns the most significant set bit of `bitboard` as a square. Asserts `bitboard != empty`.
pub inline fn msb(bitboard: Bitboard) Square {
    std.debug.assert(bitboard != empty);

    return @fromBackingInt(@intCast(@backingInt(Square.h8) - @clz(bitboard)));
}

/// Removes the least significant set bit of `bitboard` and returns it as a square.
pub inline fn popLsb(bitboard: *Bitboard) Square {
    const square = lsb(bitboard.*);

    bitboard.* &= bitboard.* - 1;

    return square;
}

/// Returns whether more than one bit is set in `bitboard`.
pub inline fn popcountGreaterThanOne(bitboard: Bitboard) bool {
    return bitboard & (bitboard -% 1) != empty;
}

/// Prints a board diagram with `X` on set squares, and the hex value.
pub fn format(bitboard: Bitboard, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const separator = "+---+---+---+---+---+---+---+---+\n";

    try writer.writeAll(separator);

    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        for (std.enums.values(File)) |file| {
            const symbol: u8 = if (bitboard & fromCoords(file, rank) == empty) ' ' else 'X';
            try writer.print("| {c} ", .{symbol});
        }

        try writer.print("| {s}\n" ++ separator, .{@tagName(rank)});
    }

    try writer.print("  a   b   c   d   e   f   g   h\nHex: 0x{x:0>16}", .{bitboard});
}
