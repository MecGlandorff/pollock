const std = @import("std");

const Color = @import("pollock").Color;

pub const Castling = packed struct(u4) {
    white_00: u1 = 0,
    white_000: u1 = 0,
    black_00: u1 = 0,
    black_000: u1 = 0,

    const CastlingInt = std.meta.Tag;
    pub const count = 16;

    pub const none: Castling = .{};
    pub const white: Castling = .{ .white_00 = 1, .white_000 = 1 };
    pub const black: Castling = .{ .black_00 = 1, .black_000 = 1 };
    pub const kingside: Castling = .{ .white_00 = 1, .black_00 = 1 };
    pub const queenside: Castling = .{ .white_000 = 1, .black_000 = 1 };

    /// Returns the castling right for `color`.
    pub inline fn right(color: Color, king: bool) Castling {
        return @bitCast(@as(CastlingInt, 1) << (@backingInt(color) * 2 + @backingInt(!king)));
    }

    /// Adds `castling_right` to `self`.
    pub inline fn addRight(self: Castling, castling_right: Castling) Castling {
        return @bitCast(@as(CastlingInt, @bitCast(self)) | @as(CastlingInt, @bitCast(castling_right)));
    }

    pub inline fn index(self: Castling) usize {
        return @as(CastlingInt, @bitCast(self));
    }
};
