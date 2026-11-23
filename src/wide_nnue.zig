//! Quantized dual-perspective evaluator with squared clipped activations.
const std = @import("std");
const king_nnue = @import("king_nnue.zig");
pub const magic = "PLKNNUE3";
pub const width = 128;
const buckets = 8;
const inputs = 768;
const heads = 8;
const qa = 255;
const V = @Vector(width, i16);
const D = @Vector(width, i32);

pub const Acc = struct {
    frames: [2]king_nnue.Frame = .{ .{}, .{} },
    values: [2][width]i16 align(32) = @splat(@splat(0)),
};

pub const Network = struct {
    feature_weights: [buckets][inputs][width]i16,
    hidden_bias: [width]i16,
    output_weights: [heads][2][width]i16,
    output_bias: [heads]i32,
    fast_sum: [heads]bool,

    fn readArray(comptime T: type, dest: anytype, rest: *[]const u8) void {
        const flat = std.mem.bytesAsSlice(T, std.mem.asBytes(dest));
        const len = @sizeOf(T);
        for (flat, 0..) |*v, i| v.* = std.mem.readInt(T, rest.*[i * len ..][0..len], .little);
        rest.* = rest.*[flat.len * len ..];
    }

    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !*Network {
        const size = 16 + 2 * (buckets * inputs * width + width + heads * 2 * width) + 4 * heads;
        if (bytes.len != size or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidWideNetwork;
        const dims = [_]u16{ buckets, inputs, width, heads };
        inline for (dims, 0..) |dim, i| {
            if (std.mem.readInt(u16, bytes[8 + 2 * i ..][0..2], .little) != dim) return error.InvalidWideNetwork;
        }
        const n = try allocator.create(Network);
        errdefer allocator.destroy(n);
        var rest = bytes[16..];
        readArray(i16, &n.feature_weights, &rest);
        readArray(i16, &n.hidden_bias, &rest);
        readArray(i16, &n.output_weights, &rest);
        readArray(i32, &n.output_bias, &rest);
        var maxima: [width]u16 = @splat(0);
        for (&n.feature_weights) |*bucket| {
            for (bucket) |*row| {
                for (row, &maxima) |v, *m| m.* = @max(m.*, @abs(v));
            }
        }
        for (n.hidden_bias, maxima) |bias, limit| {
            if (@as(u32, limit) * 32 + @abs(bias) > std.math.maxInt(i16)) return error.WideAccumulatorOverflow;
        }
        for (&n.output_weights, n.output_bias, &n.fast_sum) |*phase, bias, *fast| {
            if (@abs(bias) > 30000) return error.InvalidWideNetwork;
            var total: u64 = 0;
            for (phase) |*row| for (row) |v| {
                total += @abs(v);
            };
            fast.* = total * (qa * qa) <= std.math.maxInt(i32);
        }
        return n;
    }

    inline fn weight(self: *const Network, frame: king_nnue.Frame, side: u1, piece: u8, square: u6) V {
        return self.feature_weights[frame.bucket][king_nnue.Network.input(piece, square, side, frame.mask)];
    }

    pub fn refresh(self: *const Network, acc: *Acc, side: u1, king: u6, squares: *const [64]u8) void {
        const frame = king_nnue.Frame.init(king, side);
        var sum: V = self.hidden_bias;
        for (squares, 0..) |p, s| {
            if (p != 0) sum += self.weight(frame, side, p, @intCast(s));
        }
        acc.frames[side] = frame;
        acc.values[side] = sum;
    }

    pub const Change = struct {
        from: u6,
        to: u6,
        moving: u8,
        placed: u8,
        taken: u8,
        capture_square: u6,
        king_move: bool,
        castle: bool,
    };

    pub fn advance(self: *const Network, old: *const Acc, next: *Acc, mover: u1, move: Change, squares: *const [64]u8) void {
        inline for (0..2) |side| {
            const frame = old.frames[side];
            if (move.king_move and side == mover and !std.meta.eql(frame, king_nnue.Frame.init(move.to, mover))) {
                self.refresh(next, side, move.to, squares);
            } else {
                var sum: V = old.values[side];
                sum -= self.weight(frame, side, move.moving, move.from);
                if (move.taken != 0) sum -= self.weight(frame, side, move.taken, move.capture_square);
                sum += self.weight(frame, side, move.placed, move.to);
                if (move.castle) {
                    const short = move.to > move.from;
                    const rook_from = if (short) move.from + 3 else move.from - 4;
                    const rook_to = if (short) move.from + 1 else move.from - 1;
                    sum -= self.weight(frame, side, squares[rook_to], rook_from);
                    sum += self.weight(frame, side, squares[rook_to], rook_to);
                }
                next.frames[side] = frame;
                next.values[side] = sum;
            }
        }
    }

    inline fn products(lanes: *const [width]i16, weights: *const [width]i16) D {
        const values: V = lanes.*;
        const low: V = @splat(0);
        const high: V = @splat(qa);
        const clipped: V = @min(@max(values, low), high);
        const x: D = @intCast(clipped);
        const w: V = weights.*;
        return (x * x) * @as(D, @intCast(w));
    }

    pub fn score(self: *const Network, acc: *const Acc, material: i32, pieces: u7, side: u1) i32 {
        const phase: usize = @min((pieces - 1) / 4, heads - 1);
        const own = products(&acc.values[side], &self.output_weights[phase][0]);
        const other = products(&acc.values[side ^ 1], &self.output_weights[phase][1]);
        const Long = @Vector(width, i64);
        const total: i64 = if (self.fast_sum[phase])
            @reduce(.Add, own + other)
        else
            @reduce(.Add, @as(Long, @intCast(own))) + @reduce(.Add, @as(Long, @intCast(other)));
        const position: i32 = @intCast(@divTrunc(total, qa * qa));
        return (if (side == 0) material else -material) + position + self.output_bias[phase];
    }
};
