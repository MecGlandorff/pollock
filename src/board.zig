const std = @import("std");

const pollock = @import("pollock");
const Bitboard = pollock.bitboard.Bitboard;
const Color = pollock.Color;
const Direction = pollock.direction.Direction;

/// A board square in little-endian rank-file order: `a1` is 0, `h1` is 7, `a2` is 8 and `h8` is 63.
pub const Square = enum(u6) {
    // zig fmt: off
    a1 = 0, b1, c1, d1, e1, f1, g1, h1,
    a2,     b2, c2, d2, e2, f2, g2, h2,
    a3,     b3, c3, d3, e3, f3, g3, h3,
    a4,     b4, c4, d4, e4, f4, g4, h4,
    a5,     b5, c5, d5, e5, f5, g5, h5,
    a6,     b6, c6, d6, e6, f6, g6, h6,
    a7,     b7, c7, d7, e7, f7, g7, h7,
    a8,     b8, c8, d8, e8, f8, g8, h8,
    // zig fmt: on

    pub const SquareInt = std.meta.Tag(Square);

    /// Returns the square on `f` and `r`.
    pub inline fn fromCoords(f: File, r: Rank) Square {
        return @fromBackingInt(@intCast(@backingInt(r) * File.count + @backingInt(f)));
    }

    /// Returns `square` as seen from `color`: unchanged for white, mirrored vertically for black (`e1` becomes `e8`).
    pub inline fn relative(square: Square, color: Color) Square {
        return @fromBackingInt(@backingInt(square) ^ (@as(SquareInt, @backingInt(color)) * 56));
    }

    /// Returns `square` displaced by `direction`. The result must be on the board, so the caller has to rule out steps
    /// over an edge (e.g. `north` from rank 8 or `east` from the h-file, which would wrap to the next rank).
    pub inline fn step(square: Square, direction: Direction) Square {
        return @fromBackingInt(@intCast(@as(Direction, @backingInt(square)) + direction));
    }

    /// Returns whether `square1` comes before `square2` in square order.
    pub inline fn less(square1: Square, square2: Square) bool {
        return @backingInt(square1) < @backingInt(square2);
    }

    /// Returns the file of `square`.
    pub inline fn file(square: Square) File {
        return @fromBackingInt(@intCast(@backingInt(square) % File.count));
    }

    /// Returns the rank of `square`.
    pub inline fn rank(square: Square) Rank {
        return @fromBackingInt(@intCast(@backingInt(square) / File.count));
    }

    /// Returns whether `square1` and `square2` lie on the same file.
    pub inline fn sameFile(square1: Square, square2: Square) bool {
        return (@backingInt(square1) ^ @backingInt(square2)) % File.count == 0;
    }

    /// Returns the bitboard with only `square` set.
    pub inline fn bitboard(square: Square) Bitboard {
        return @as(Bitboard, 1) << @backingInt(square);
    }
};

pub const File = enum(u3) {
    a = 0,
    b,
    c,
    d,
    e,
    f,
    g,
    h,

    const FileInt = std.meta.Tag(File);
    pub const count = std.enums.values(File).len;

    /// Returns the file for the character `a`-`h`, or `null` for any other character.
    pub inline fn fromChar(char: u8) ?File {
        if (char < 'a')
            return null;

        return std.enums.fromInt(File, char - 'a');
    }

    /// Returns the character `a`-`h` of `file`.
    pub inline fn toChar(file: File) u8 {
        return @backingInt(file) + 'a';
    }

    /// Returns the bitboard of all squares on `file`.
    pub inline fn bitboard(file: File) Bitboard {
        return @as(Bitboard, 0x0101010101010101) << @backingInt(file);
    }
};

pub const Rank = enum(u3) {
    @"1" = 0,
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",

    const RankInt = std.meta.Tag(Rank);

    /// Returns the rank for the character `1`-`8`, or `null` for any other character.
    pub inline fn fromChar(char: u8) ?Rank {
        if (char < '1')
            return null;

        return std.enums.fromInt(Rank, char - '1');
    }

    /// Returns the character `1`-`8` of `rank`.
    pub inline fn toChar(rank: Rank) u8 {
        return @backingInt(rank) + '1';
    }

    /// Returns the bitboard of all squares on `rank`.
    pub inline fn bitboard(rank: Rank) Bitboard {
        const shift = @as(Square.SquareInt, File.count) * @backingInt(rank);

        return @as(Bitboard, 0x00000000000000FF) << shift;
    }

    /// Returns `rank` as seen from `color`: unchanged for white, mirrored for black (rank 1 becomes rank 8).
    pub inline fn relative(rank: Rank, color: Color) Rank {
        return @fromBackingInt(@backingInt(rank) ^ @as(RankInt, @backingInt(color)) * 7);
    }
};
