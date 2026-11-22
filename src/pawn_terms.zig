//! Signed, color-symmetric pawn-structure features for the optional learned output.
const file_a: u64 = 0x0101010101010101;
const file_h = file_a << 7;
pub const Count = 12;
pub const Weights = [3][Count]i16;

fn adjacent(pawns: u64) u64 {
    return ((pawns & ~file_h) << 1) | ((pawns & ~file_a) >> 1);
}

fn south(bits: u64) u64 {
    var spread = bits | (bits >> 8);
    spread |= spread >> 16;
    return spread | (spread >> 32);
}

fn onFiles(bits: u64) u64 {
    var spread = south(bits);
    spread |= spread << 8;
    spread |= spread << 16;
    return spread | (spread << 32);
}

fn counts(own: u64, enemy: u64) [Count]i32 {
    const other_files = adjacent(onFiles(own));
    const defended = own & adjacent(own << 8);
    const passed = own & ~south((enemy | adjacent(enemy)) >> 8);
    var result: [Count]i32 = undefined;
    result[0] = @popCount(own & ~other_files);
    result[1] = @popCount(own & south(own >> 8));
    result[2] = @popCount(defended);
    result[3] = @popCount(own & adjacent(own));
    inline for (1..7) |rank| {
        result[3 + rank] = @popCount(@as(u8, @truncate(passed >> (8 * rank))));
    }
    result[10] = @popCount(passed & defended);
    result[11] = @popCount(passed & adjacent(passed));
    return result;
}

pub fn score(weights: *const Weights, white: u64, black: u64) [3]i32 {
    const w = counts(white, black);
    const b = counts(@byteSwap(black), @byteSwap(white));
    var totals: [3]i32 = @splat(0);
    for (0..Count) |i| {
        const difference = w[i] - b[i];
        inline for (0..3) |phase| totals[phase] += weights[phase][i] * difference;
    }
    return totals;
}
