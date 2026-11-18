const std = @import("std");

pub const Castling = packed struct(u4) {
    white_00: u1 = 0,
    white_000: u1 = 0,
    black_00: u1 = 0,
    black_000: u1 = 0,

    pub const count = 16;

    pub const none: Castling = .{};
    pub const white: Castling = .{ .white_00 = 1, .white_000 = 1 };
    pub const black: Castling = .{ .black_00 = 1, .black_000 = 1 };
    pub const king_side: Castling = .{ .white_00 = 1, .black_00 = 1 };
    pub const queen_side: Castling = .{ .white_000 = 1, .black_000 = 1 };
};
