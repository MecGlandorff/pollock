//! Quantized king-relative network. Two accumulators share one set of learned weights.
const std = @import("std");
const pawn_terms = @import("pawn_terms.zig");
const width = 32;
const buckets = 8;
const inputs = 768;
const V = @Vector(width, i32);
pub const material = [_]i32{ 100, 325, 325, 500, 900, 0 };
pub const phase_weight = [_]u8{ 0, 1, 1, 2, 4, 0 };

pub const Frame = struct {
    bucket: u3 = 0,
    mask: u6 = 0,

    pub fn init(king: u6, side: u1) Frame {
        const vertical: u6 = if (side == 0) 0 else 56;
        const horizontal: u6 = if (king % 8 >= 4) 7 else 0;
        const square = king ^ vertical ^ horizontal;
        const file_group: u6 = (square % 8) / 2;
        const rank_group: u6 = @min(square / 8, 3);
        return .{ .bucket = @intCast(file_group + 2 * rank_group), .mask = vertical ^ horizontal };
    }
};
pub const Acc = struct {
    frames: [2]Frame = .{ .{}, .{} },
    values: [2]V = .{ @splat(0), @splat(0) },
};

pub const Network = struct {
    feature_weights: [buckets][inputs][width]i16,
    hidden_bias: [width]i16,
    output_weights: [3][width]i16,
    tempo: [3]i16,
    pawn_weights: ?pawn_terms.Weights = null,

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !*Network {
        const Wire = struct {
            version: u8,
            score_unit: enum { centipawns },
            feature_weights: []const []const [width]i16,
            hidden_bias: [width]i16,
            output_weights: [3][width]i16,
            tempo: [3]i16,
            pawn_weights: ?pawn_terms.Weights = null,
        };
        const json = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
        defer json.deinit();
        if (json.value.version != 2 or json.value.feature_weights.len != buckets) return error.InvalidKingNetwork;
        const net = try allocator.create(Network);
        errdefer allocator.destroy(net);
        net.hidden_bias = json.value.hidden_bias;
        net.output_weights = json.value.output_weights;
        net.tempo = json.value.tempo;
        net.pawn_weights = json.value.pawn_weights;
        for (&net.feature_weights, json.value.feature_weights) |*dst, rows| {
            if (rows.len != inputs) return error.InvalidKingNetwork;
            @memcpy(dst, rows);
        }
        return net;
    }

    pub inline fn input(piece: u8, square: u6, side: u1, mask: u6) usize {
        const original = piece - 1;
        const plane = if (side == 0) original else if (original < 6) original + 6 else original - 6;
        return @as(usize, plane) * 64 + (square ^ mask);
    }

    inline fn row(self: *const Network, frame: Frame, side: u1, p: u8, s: u6) V {
        const narrow: @Vector(width, i16) = self.feature_weights[frame.bucket][input(p, s, side, frame.mask)];
        return @intCast(narrow);
    }

    pub fn refresh(self: *const Network, acc: *Acc, side: u1, king: u6, squares: *const [64]u8) void {
        const frame = Frame.init(king, side);
        const bias: @Vector(width, i16) = self.hidden_bias;
        var sum: V = @intCast(bias);
        for (squares, 0..) |p, s| {
            if (p != 0) sum += self.row(frame, side, p, @intCast(s));
        }
        acc.frames[side] = frame;
        acc.values[side] = sum;
    }

    pub inline fn update(self: *const Network, acc: *Acc, p: u8, s: u6, add: bool) void {
        inline for (0..2) |i| {
            const w = self.row(acc.frames[i], i, p, s);
            acc.values[i] = if (add) acc.values[i] + w else acc.values[i] - w;
        }
    }

    pub fn phaseIndex(phase_count: u8) usize {
        return @as(usize, @intFromBool(phase_count > 6)) + @intFromBool(phase_count > 15);
    }

    pub fn score(self: *const Network, acc: *const Acc, mat: i32, phase_count: u8, side: u1) i32 {
        const phase = phaseIndex(phase_count);
        const zero: V = @splat(0);
        const limit: V = @splat(256);
        const white_lanes: V = @min(@max(acc.values[0], zero), limit);
        const black_lanes: V = @min(@max(acc.values[1], zero), limit);
        const difference = white_lanes - black_lanes;
        const narrow: @Vector(width, i16) = self.output_weights[phase];
        const head: V = @intCast(narrow);
        const white = mat + @divTrunc(@reduce(.Add, difference * head), 256);
        return (if (side == 0) white else -white) + self.tempo[phase];
    }
};
