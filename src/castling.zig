const std = @import("std");

const pollock = @import("pollock");
const Color = pollock.Color;

/// A set of castling rights. Bit 0 is white kingside, bit 1 white queenside, bit 2 black kingside, bit 3 black
/// queenside. The 16 possible sets index the Zobrist castling keys (see `index`).
pub const Castling = packed struct(u4) {
    /// White kingside (0-0).
    white_00: u1 = 0,
    /// White queenside (0-0-0).
    white_000: u1 = 0,
    /// Black kingside (0-0).
    black_00: u1 = 0,
    /// Black queenside (0-0-0).
    black_000: u1 = 0,

    const CastlingInt = @typeInfo(Castling).@"struct".backing_integer.?;

    /// Number of distinct sets of rights.
    pub const count = 1 << @bitSizeOf(Castling);

    pub const none: Castling = .{};
    pub const white: Castling = .{ .white_00 = 1, .white_000 = 1 };
    pub const black: Castling = .{ .black_00 = 1, .black_000 = 1 };
    pub const kingside: Castling = .{ .white_00 = 1, .black_00 = 1 };
    pub const queenside: Castling = .{ .white_000 = 1, .black_000 = 1 };

    /// Returns the single castling right of `color` on the king's side (`king == true`) or the queen's side.
    pub inline fn right(color: Color, king: bool) Castling {
        const shift: u2 = @as(u2, @backingInt(color)) * 2 + @intFromBool(!king);
        return @fromBackingInt(@as(CastlingInt, 1) << shift);
    }

    /// Adds the rights in `mask` to `castling`.
    pub inline fn addRight(castling: *Castling, mask: Castling) void {
        castling.* = @fromBackingInt(@backingInt(castling.*) | @backingInt(mask));
    }

    /// Removes the rights in `mask` from `castling`.
    pub inline fn removeRight(castling: *Castling, mask: Castling) void {
        castling.* = @fromBackingInt(@backingInt(castling.*) & ~@backingInt(mask));
    }

    /// Returns whether `castling` contains any of the rights in `mask`.
    pub inline fn has(castling: Castling, mask: Castling) bool {
        return @backingInt(castling) & @backingInt(mask) != 0;
    }

    /// Returns the value of the set as an integer below `count`. For a single right (see `right`) this is 1, 2, 4 or 8.
    pub inline fn index(castling: Castling) usize {
        return @backingInt(castling);
    }
};
