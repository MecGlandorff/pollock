const std = @import("std");

const pollock = @import("pollock");
const Bitboard = pollock.bitboard.Bitboard;
const Color = @import("pollock").Color;

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

    const SquareInt = std.meta.Tag(Square);
    pub const Step = @Int(.signed, @bitSizeOf(SquareInt) + 1);

    pub const north: Step = 8;
    pub const south: Step = -north;
    pub const east: Step = 1;
    pub const west: Step = -east;
    pub const northeast: Step = north + east;
    pub const northwest: Step = north + west;
    pub const southeast: Step = south + east;
    pub const southwest: Step = south + west;

    /// Returns the square on `file` and `rank`.
    pub inline fn fromCoords(f: File, r: Rank) Square {
        return @fromBackingInt(@intCast(@as(SquareInt, @backingInt(f)) * east | @backingInt(r) * north));
    }

    /// Returns `square` displaced by `square_step`.
    pub inline fn step(square: Square, square_step: Step) Square {
        return @fromBackingInt(@intCast(@backingInt(square) + square_step));
    }

    /// Returns `square` relative to `color`.
    pub inline fn relative(square: Square, color: Color) Square {
        return @fromBackingInt(@backingInt(square) ^ (@as(SquareInt, @backingInt(color)) * 56));
    }

    /// Returns whether `self` is less than `square`.
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

    /// Returns `true` if `square1` and `square2` lie on the same file. Else returns `false`.
    pub inline fn sameFile(square1: Square, square2: Square) bool {
        return (@backingInt(square1) ^ @backingInt(square2)) % File.count == 0;
    }

    /// Returns a bitboard of `square`.
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

    pub const Step = @Int(.signed, @bitSizeOf(FileInt) + 1);
    pub const east: Step = 1;
    pub const west: Step = -east;

    /// Returns the `File` corresponding to `char`.
    pub inline fn fromChar(char: u8) File {
        return @fromBackingInt(@intCast(char - 'a'));
    }

    /// Returns the character of `file`.
    pub inline fn toChar(file: File) u8 {
        return @backingInt(file) + 'a';
    }

    /// Returns a bitboard of `file`.
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

    pub const Step = @Int(.signed, @bitSizeOf(RankInt) + 1);
    pub const north: Step = 1;
    pub const south: Step = -north;

    /// Returns the `Rank` corresponding to `char`.
    pub inline fn fromChar(char: u8) Rank {
        return @fromBackingInt(@intCast(char - '1'));
    }

    /// Returns the character of `rank`.
    pub inline fn toChar(rank: Rank) u8 {
        return @backingInt(rank) + '1';
    }

    /// Returns a bitboard of `rank`.
    pub inline fn bitboard(rank: Rank) Bitboard {
        return @as(Bitboard, 0x00000000000000FF) << @backingInt(rank);
    }

    /// Returns the back rank of `color`.
    pub inline fn backRank(color: Color) Rank {
        return @fromBackingInt(color * @backingInt(Rank.@"8"));
    }
};
