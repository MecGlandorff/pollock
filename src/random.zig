const std = @import("std");

pub const XorShift64Star = struct {
    state: u64,

    /// Creates a new `XorShift64Star` with `seed`. `seed` must be non-zero.
    pub fn create(seed: u64) XorShift64Star {
        std.debug.assert(seed != 0);

        return .{ .state = seed };
    }

    /// Returns a pseudorandom `u64`.
    pub fn rand(self: *XorShift64Star) u64 {
        std.debug.assert(self.state != 0);

        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;

        return self.state *% 0x2545F4914F6CDD1D;
    }

    /// Returns a sparse pseudorandom `u64` with on average 1/8th of the bits set.
    pub fn sparse(self: *XorShift64Star) u64 {
        return self.rand() & self.rand() & self.rand();
    }
};
