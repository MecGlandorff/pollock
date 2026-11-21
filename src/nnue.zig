//! Pollock v0 piece-square NNUE. Weights use absolute board coordinates.

const std = @import("std");
const pollock = @import("pollock");

const hidden_size = 16;
const Layer = Accumulator(hidden_size);

/// Planes are PNBRQKpnbrqk. Within each plane, a1 is 0 and h8 is 63.
pub fn featureIndex(piece: pollock.Piece, square: pollock.Square) usize {
    const plane = @as(usize, @backingInt(piece.color)) * 6 + @backingInt(piece.type);
    return plane * 64 + @backingInt(square);
}

pub const Network = struct {
    version: u8,
    score_unit: enum { centipawns, outcome_per_mille } = .centipawns,
    feature_weights: [12 * 64]Layer.WeightRow,
    hidden_bias: [hidden_size]i16,
    output_weights: [hidden_size]i16,
    output_bias: i32,

    pub fn load(allocator: std.mem.Allocator, json: []const u8) !Network {
        const parsed = try std.json.parseFromSlice(Network, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.UnsupportedNnueVersion;
        return parsed.value;
    }

    pub fn refresh(net: *const Network, position: *const pollock.Position) Layer {
        var active: [64]usize = undefined;
        var count: usize = 0;
        for (std.enums.values(pollock.Square)) |square| {
            if (position.board.get(square)) |piece| {
                active[count] = featureIndex(piece, square);
                count += 1;
            }
        }
        var bias: [hidden_size]i32 = undefined;
        for (&bias, net.hidden_bias) |*sum, initial| sum.* = initial;
        return Layer.refresh(bias, &net.feature_weights, active[0..count]);
    }

    /// Apply only changed piece-square rows. Swapping the two positions undoes the update.
    pub fn update(net: *const Network, layer: *Layer, before: *const pollock.Position, after: *const pollock.Position) void {
        for (std.enums.values(pollock.Square)) |square| {
            const old = before.board.get(square);
            const new = after.board.get(square);
            if (old == new) continue;
            if (old) |piece| layer.update(&net.feature_weights, &.{featureIndex(piece, square)}, &.{});
            if (new) |piece| layer.update(&net.feature_weights, &.{}, &.{featureIndex(piece, square)});
        }
    }

    /// Returns a score for the side to move in the unit stored in the network.
    pub fn score(net: *const Network, layer: *const Layer, turn: pollock.Color) i64 {
        var sum = @as(i64, net.output_bias) * 256;
        for (layer.values, net.output_weights) |value, weight| {
            sum += @as(i64, std.math.clamp(value, 0, 256)) * weight;
        }
        const raw = @divTrunc(sum, 256);
        const white = if (net.score_unit == .outcome_per_mille) std.math.clamp(raw, -1000, 1000) else raw;
        return if (turn == .white) white else -white;
    }
};

pub fn Accumulator(comptime width: usize) type {
    return struct {
        const Self = @This();
        pub const WeightRow = [width]i16;

        values: [width]i32,

        /// Each active feature is the index of one row in the weight table.
        pub fn refresh(bias: [width]i32, weights: []const WeightRow, active: []const usize) Self {
            var result = Self{ .values = bias };
            result.update(weights, &.{}, active);
            return result;
        }

        /// Swapping the removed and added features reverses the move's update.
        pub fn update(self: *Self, weights: []const WeightRow, removed: []const usize, added: []const usize) void {
            for (removed) |feature| {
                for (&self.values, &weights[feature]) |*sum, weight| {
                    sum.* -= weight;
                }
            }
            for (added) |feature| {
                for (&self.values, &weights[feature]) |*sum, weight| {
                    sum.* += weight;
                }
            }
        }
    };
}
