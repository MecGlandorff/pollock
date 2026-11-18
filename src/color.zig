pub const Color = enum(u1) {
    white = 0,
    black,

    /// Returns the opposite of `color`.
    pub inline fn opposite(color: Color) Color {
        return @fromBackingInt(@backingInt(color) ^ @backingInt(Color.black));
    }
};
