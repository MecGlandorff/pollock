const std = @import("std");

/// The xorshift64* pseudorandom number generator, see https://en.wikipedia.org/wiki/Xorshift#xorshift*. Small and
/// fast, and deterministic for a given seed, which makes it suitable for comptime tables such as Zobrist keys and magic
/// number search. Not suitable for cryptography.
pub const XorShift64Star = struct {
    /// Never zero, since zero is a fixed point of the xorshift step.
    state: u64,

    /// Creates a generator with `seed`. `seed` must be non-zero.
    pub fn create(seed: u64) XorShift64Star {
        std.debug.assert(seed != 0);

        return .{ .state = seed };
    }

    /// Returns the next pseudorandom `u64`.
    pub fn rand(self: *XorShift64Star) u64 {
        self.state ^= self.state >> 12;
        self.state ^= self.state << 25;
        self.state ^= self.state >> 27;

        // The multiplication scrambles the low-quality low bits of the xorshift state.
        return self.state *% 0x2545F4914F6CDD1D;
    }
};
