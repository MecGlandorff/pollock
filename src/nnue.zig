//! Piece-square and king-relative NNUE inference.

const std = @import("std");
const pollock = @import("pollock");

const king = @import("king_nnue.zig");
const KingNetwork = king.Network;
const wide = @import("wide_nnue.zig");
const board_eval = @import("board_eval.zig");
const ScoreUnit = enum { centipawns, outcome_per_mille };
const hidden_size = 16;
const Layer = Accumulator(hidden_size);

/// Planes are PNBRQKpnbrqk. Within each plane, a1 is 0 and h8 is 63.
pub fn featureIndex(piece: pollock.Piece, square: pollock.Square) usize {
    const plane = @as(usize, @backingInt(piece.color)) * 6 + @backingInt(piece.type);
    return plane * 64 + @backingInt(square);
}

pub const Network = struct {
    version: u8,
    score_unit: ScoreUnit = .centipawns,
    feature_weights: [12 * 64]Layer.WeightRow,
    hidden_bias: [hidden_size]i16,
    output_weights: [hidden_size]i16,
    output_bias: i32,

    king_net: ?*KingNetwork = null,
    wide_net: ?*wide.Network = null,

    pub fn load(allocator: std.mem.Allocator, json: []const u8) !Network {
        if (std.mem.startsWith(u8, json, wide.magic)) {
            var net = std.mem.zeroes(Network);
            net.version = 3;
            net.wide_net = try wide.Network.load(allocator, json);
            return net;
        }
        const header = try std.json.parseFromSlice(struct { version: u8 }, allocator, json, .{ .ignore_unknown_fields = true });
        defer header.deinit();
        if (header.value.version == 2) {
            var n = std.mem.zeroes(Network);
            n.version = 2;
            n.king_net = try KingNetwork.load(allocator, json);
            return n;
        }
        if (header.value.version != 1) return error.UnsupportedNnueVersion;
        const Legacy = struct {
            version: u8,
            score_unit: ScoreUnit = .centipawns,
            feature_weights: [12 * 64]Layer.WeightRow,
            hidden_bias: [hidden_size]i16,
            output_weights: [hidden_size]i16,
            output_bias: i32,
        };
        const parsed = try std.json.parseFromSlice(Legacy, allocator, json, .{});
        defer parsed.deinit();
        return .{ .version = 1, .score_unit = parsed.value.score_unit, .feature_weights = parsed.value.feature_weights, .hidden_bias = parsed.value.hidden_bias, .output_weights = parsed.value.output_weights, .output_bias = parsed.value.output_bias };
    }

    pub fn deinit(n: *Network, allocator: std.mem.Allocator) void {
        if (n.king_net) |k| allocator.destroy(k);
        n.king_net = null;
        if (n.wide_net) |w| allocator.destroy(w);
        n.wide_net = null;
    }

    /// Refresh a validated position. Use refreshChecked for externally supplied positions.
    pub fn refresh(net: *const Network, position: *const pollock.Position) Layer {
        return net.refreshChecked(position) catch |err| std.debug.panic("invalid NNUE position: {s}", .{@errorName(err)});
    }

    pub fn refreshChecked(net: *const Network, position: *const pollock.Position) !Layer {
        if (net.wide_net) |n| {
            try board_eval.validate(position);
            const acc = board_eval.refresh(position, n);
            const count = @popCount(position.totalOccupancy());
            return .{ .perspectives = .{ n.score(&acc.wide, acc.balance, count, 0), n.score(&acc.wide, acc.balance, count, 1) } };
        }
        if (net.king_net) |n| {
            var acc: king.Acc = .{};
            const squares = board_eval.squareCodes(position);
            var material_cp: i32 = 0;
            var phase_count: u8 = 0;
            inline for (std.enums.values(pollock.Color)) |side| {
                if (@popCount(position.pieceOccupancy(side, .king)) != 1) return error.InvalidKings;
                n.refresh(&acc, @backingInt(side), @backingInt(position.kingSquare(side)), &squares);
                inline for (std.enums.values(pollock.Piece.Type)) |kind| {
                    const count = @popCount(position.pieceOccupancy(side, kind));
                    const mat = king.material[@backingInt(kind)] * @as(i32, count);
                    material_cp += if (side == .white) mat else -mat;
                    phase_count += @as(u8, count) * king.phase_weight[@backingInt(kind)];
                }
            }
            if (n.pawn_weights) |*weights| {
                const scores = @import("pawn_terms.zig").score(weights, position.pieceOccupancy(.white, .pawn), position.pieceOccupancy(.black, .pawn));
                material_cp += scores[KingNetwork.phaseIndex(phase_count)];
            }
            return .{ .perspectives = .{ n.score(&acc, material_cp, phase_count, 0), n.score(&acc, material_cp, phase_count, 1) } };
        }

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

    /// Update between validated positions. Swapping them undoes the update.
    pub fn update(net: *const Network, layer: *Layer, before: *const pollock.Position, after: *const pollock.Position) void {
        net.updateChecked(layer, before, after) catch |err| std.debug.panic("invalid NNUE position: {s}", .{@errorName(err)});
    }

    pub fn updateChecked(net: *const Network, layer: *Layer, before: *const pollock.Position, after: *const pollock.Position) !void {
        // Arbitrary FEN pairs can change either king's frame. Search updates a known move in board_eval.
        if (net.king_net != null or net.wide_net != null) {
            layer.* = try net.refreshChecked(after);
            return;
        }
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
        if (layer.* == .perspectives) return layer.perspectives[@backingInt(turn)];
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
    return union(enum) {
        const Self = @This();
        pub const WeightRow = [width]i16;

        values: [width]i32,
        /// King-relative heads can give different scores for each side to move, including tempo.
        perspectives: [2]i32,

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
