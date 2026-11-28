//! Quantized dual-perspective evaluator with squared clipped activations.
const std = @import("std");
const king_nnue = @import("king_nnue.zig");
pub const magic = "PLKNNUE3";
pub const width = 1024;
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
    square_correction: [heads]i32,
    chunk_safe: [heads]bool,
    chunk_correction: [heads]i64,

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
        try n.prepareOutput();
        return n;
    }

    pub fn prepareOutput(n: *Network) !void {
        for (&n.output_weights, n.output_bias, &n.fast_sum, &n.square_correction, 0..) |*phase, bias, *fast, *correction, index| {
            if (@abs(bias) > 30000) return error.InvalidWideNetwork;
            var total: u64 = 0;
            var signed: i32 = 0;
            for (phase) |*row| for (row) |v| {
                total += @abs(v);
                signed += v;
            };
            fast.* = total * (qa * qa) <= std.math.maxInt(i32);
            correction.* = if (fast.*) signed * 32768 else 0;
            var safe = true;
            for (0..width / 128) |group| {
                var norm: u32 = 0;
                for (phase) |*row| {
                    for (row[group * 128 ..][0..128]) |v| norm += @abs(v);
                }
                if (norm > 65535) {
                    safe = false;
                    break;
                }
            }
            n.chunk_safe[index] = safe;
            n.chunk_correction[index] = @as(i64, signed) * 32768;
        }
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

    pub const RookChange = struct { piece: u8, from: u6, to: u6 };

    const Chunk = @Vector(16, i16);

    inline fn column(self: *const Network, frame: king_nnue.Frame, side: u1, piece: u8, square: u6) *const [width]i16 {
        return &self.feature_weights[frame.bucket][king_nnue.Network.input(piece, square, side, frame.mask)];
    }

    inline fn updateColumns(old: *const [width]i16, dest: *[width]i16, removed: anytype, added: anytype) void {
        for (0..width / 16) |block| {
            const off = block * 16;
            var sum: Chunk = old[off..][0..16].*;
            inline for (removed) |row| sum -= @as(Chunk, row[off..][0..16].*);
            inline for (added) |row| sum += @as(Chunk, row[off..][0..16].*);
            dest[off..][0..16].* = sum;
        }
    }

    pub fn advanceInFrame(self: *const Network, old: *const Acc, next: *Acc, side: u1, move: Change, rook: ?RookChange) void {
        const frame = old.frames[side];
        const before = self.column(frame, side, move.moving, move.from);
        const after = self.column(frame, side, move.placed, move.to);
        const parent = &old.values[side];
        const child = &next.values[side];
        next.frames[side] = frame;
        if (rook) |r| {
            const rook_from = self.column(frame, side, r.piece, r.from);
            const rook_to = self.column(frame, side, r.piece, r.to);
            if (move.taken != 0) {
                const captured = self.column(frame, side, move.taken, move.capture_square);
                updateColumns(parent, child, .{ before, captured, rook_from }, .{ after, rook_to });
            } else {
                updateColumns(parent, child, .{ before, rook_from }, .{ after, rook_to });
            }
        } else if (move.taken != 0) {
            const captured = self.column(frame, side, move.taken, move.capture_square);
            updateColumns(parent, child, .{ before, captured }, .{after});
        } else {
            updateColumns(parent, child, .{before}, .{after});
        }
    }


    pub fn advance(self: *const Network, old: *const Acc, next: *Acc, mover: u1, move: Change, squares: *const [64]u8) void {
        const rook: ?RookChange = if (move.castle) blk: {
            const short = move.to > move.from;
            const from = if (short) move.from + 3 else move.from - 4;
            const to = if (short) move.from + 1 else move.from - 1;
            break :blk .{ .piece = squares[to], .from = from, .to = to };
        } else null;
        inline for (0..2) |side| {
            const frame = old.frames[side];
            if (move.king_move and side == mover and !std.meta.eql(frame, king_nnue.Frame.init(move.to, mover))) {
                self.refresh(next, side, move.to, squares);
            } else {
                self.advanceInFrame(old, next, side, move, rook);
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

    const Lanes = @Vector(16, i16);
    const Sums = @Vector(8, i32);
    const use_avx2 = blk: {
        const cpu = @import("builtin").target.cpu;
        break :blk cpu.arch == .x86_64 and std.Target.x86.featureSetHas(cpu.features, .avx2);
    };

    inline fn squareDot(lanes: *const [16]i16, weights: *const [16]i16) Sums {
        const value: Lanes = lanes.*;
        const clipped: Lanes = @min(@max(value, @as(Lanes, @splat(0))), @as(Lanes, @splat(qa)));
        // Signed PMADDWD sees x² - 32768. Loading the head precomputes
        // 32768 times its weight sum to reconstruct the exact original dot.
        const centered = (clipped *% clipped) ^ @as(Lanes, @splat(-32768));
        const w: Lanes = weights.*;
        return asm ("vpmaddwd %[w], %[x], %[sum]"
            : [sum] "=x" (-> Sums),
            : [x] "x" (centered),
              [w] "x" (w),
        );
    }

    fn fastScore(self: *const Network, acc: *const Acc, phase: usize, side: u1) i32 {
        var mine: Sums = @splat(0);
        var theirs: Sums = @splat(0);
        for (0..width / 64) |tile| {
            inline for (0..4) |j| {
                const a = tile * 64 + j * 16;
                mine += squareDot(acc.values[side][a..][0..16], self.output_weights[phase][0][a..][0..16]);
                theirs += squareDot(acc.values[side ^ 1][a..][0..16], self.output_weights[phase][1][a..][0..16]);
            }
        }
        return @reduce(.Add, mine + theirs) + self.square_correction[phase];
    }


    // Every admitted group bounds the absolute sum of all centered products to
    // 32768 * 65535. Every PMADDWD pair, intermediate lane and group reduce fits i32.
    fn chunkedScore(self: *const Network, acc: *const Acc, phase: usize, side: u1) i64 {
        var total = self.chunk_correction[phase];
        for (0..width / 128) |group| {
            var mine: Sums = @splat(0);
            var theirs: Sums = @splat(0);
            inline for (0..128 / 16) |block| {
                const a = group * 128 + block * 16;
                mine += squareDot(acc.values[side][a..][0..16], self.output_weights[phase][0][a..][0..16]);
                theirs += squareDot(acc.values[side ^ 1][a..][0..16], self.output_weights[phase][1][a..][0..16]);
            }
            total += @as(i64, @reduce(.Add, mine + theirs));
        }
        return total;
    }

    pub fn score(self: *const Network, acc: *const Acc, material: i32, pieces: u7, side: u1) i32 {
        const phase: usize = @min((pieces - 1) / 4, heads - 1);
        if (comptime use_avx2) {
            if (self.fast_sum[phase]) {
                const position = @divTrunc(self.fastScore(acc, phase, side), qa * qa);
                return (if (side == 0) material else -material) + position + self.output_bias[phase];
            }
            if (self.chunk_safe[phase]) {
                const position: i32 = @intCast(@divTrunc(self.chunkedScore(acc, phase, side), qa * qa));
                return (if (side == 0) material else -material) + position + self.output_bias[phase];
            }
        }
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
