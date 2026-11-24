const std = @import("std");
const pollock = @import("pollock");

test "Nxc3 captures a queen, updates the accumulator and can be undone" {
    var net = std.mem.zeroes(pollock.nnue.Network);
    // These three piece-square rows suffice for the two positions. The a-pawns cancel.
    // Separate lanes for b1 and c3 expose a missed knight relocation even at equal material.
    net.feature_weights[65][0] = 16; // White knight b1
    net.feature_weights[82][1] = 16; // White knight c3
    net.feature_weights[658][2] = 16; // Black queen c3
    net.output_weights[0] = 16 * 320;
    net.output_weights[1] = 16 * 320;
    net.output_weights[2] = -16 * 900;

    var before: pollock.Position = undefined;
    var after: pollock.Position = undefined;
    var before_state: pollock.Position.State = undefined;
    var after_state: pollock.Position.State = undefined;
    _ = try before.setFen(&before_state, "7k/p7/8/8/8/2q5/P7/1N5K w - - 0 1", false);
    _ = try after.setFen(&after_state, "7k/p7/8/8/8/2N5/P7/7K b - - 0 1", false);

    const original = net.refresh(&before);
    var updated = original;
    try std.testing.expectEqual(@as(i64, -580), net.score(&original, before.side_to_move));
    net.update(&updated, &before, &after);
    const rebuilt = net.refresh(&after);
    try std.testing.expectEqualSlices(i32, &rebuilt.values, &updated.values);
    try std.testing.expectEqual(@as(i64, -320), net.score(&updated, after.side_to_move));
    net.update(&updated, &after, &before);
    try std.testing.expectEqualSlices(i32, &original.values, &updated.values);
}
