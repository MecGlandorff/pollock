//! Compact standard-chess position used by move generation and search.
const std = @import("std");
const pollock = @import("pollock");
pub const Move = pollock.Move;
pub const Network = pollock.nnue.Network;
const Layer = pollock.nnue.Accumulator(16);
const king_nnue = @import("king_nnue.zig");
const wide_nnue = @import("wide_nnue.zig");
const pawn_terms = @import("pawn_terms.zig");
const Sq = u6;
const SquareSet = u64;
pub const pawn = 0;
pub const knight = 1;
pub const bishop = 2;
pub const rook = 3;
pub const queen = 4;
pub const king = 5;
pub const values = [_]i32{ 100, 325, 330, 500, 950, 20000 };
const empty_ep = 64;

pub fn from(m: Move) Sq {
    return @backingInt(m.source);
}
pub fn to(m: Move) Sq {
    return @backingInt(m.destination);
}
pub fn bits(m: Move) u16 {
    return @bitCast(m);
}
pub fn kind(p: u8) usize {
    return (p - 1) % 6;
}
fn color(p: u8) u1 {
    return @intCast((p - 1) / 6);
}
fn piece(side: u1, k: usize) u8 {
    return 1 + @as(u8, side) * 6 + @as(u8, @intCast(k));
}
fn bit(s: Sq) SquareSet {
    return @as(u64, 1) << s;
}
fn pop(b: *SquareSet) Sq {
    const s: Sq = @intCast(@ctz(b.*));
    b.* &= b.* - 1;
    return s;
}

const Delta = struct { f: i8, r: i8 };
const directions = [_]Delta{
    .{ .f = 1, .r = 0 }, .{ .f = -1, .r = 0 }, .{ .f = 0, .r = 1 },  .{ .f = 0, .r = -1 },
    .{ .f = 1, .r = 1 }, .{ .f = -1, .r = 1 }, .{ .f = 1, .r = -1 }, .{ .f = -1, .r = -1 },
};
const jumps = [_]Delta{
    .{ .f = 1, .r = 2 }, .{ .f = -1, .r = 2 }, .{ .f = 1, .r = -2 }, .{ .f = -1, .r = -2 },
    .{ .f = 2, .r = 1 }, .{ .f = -2, .r = 1 }, .{ .f = 2, .r = -1 }, .{ .f = -2, .r = -1 },
};

fn step(s: Sq, d: Delta) ?Sq {
    const f = @as(i8, s % 8) + d.f;
    const r = @as(i8, s / 8) + d.r;
    if (f < 0 or f > 7 or r < 0 or r > 7) return null;
    return @intCast(r * 8 + f);
}

const Tables = struct {
    knights: [64]u64,
    kings: [64]u64,
    pawns: [2][64]u64,
    rays: [8][64]u64,
};
const attacks = blk: {
    @setEvalBranchQuota(150000);
    var table = std.mem.zeroes(Tables);
    for (0..64) |i| {
        const s: Sq = @intCast(i);
        for (jumps) |d| if (step(s, d)) |dst| {
            table.knights[i] |= bit(dst);
        };
        for (directions, 0..) |d, j| {
            if (step(s, d)) |dst| {
                table.kings[i] |= bit(dst);
                if (d.f != 0 and d.r != 0) table.pawns[@intFromBool(d.r < 0)][i] |= bit(dst);
            }
            var next = step(s, d);
            while (next) |dst| : (next = step(dst, d)) table.rays[j][i] |= bit(dst);
        }
    }
    break :blk table;
};

fn rayAttacks(s: Sq, occ: u64, comptime diagonal: bool) u64 {
    var result: u64 = 0;
    const start = if (diagonal) 4 else 0;
    inline for (start..start + 4) |i| {
        const ray = attacks.rays[i][s];
        const blockers = ray & occ;
        var available = ray;
        if (blockers != 0) {
            const d = directions[i];
            const first: Sq = if (d.r * 8 + d.f > 0)
                @intCast(@ctz(blockers))
            else
                @intCast(63 - @clz(blockers));
            available ^= attacks.rays[i][first];
        }
        result |= available;
    }
    return result;
}

/// Edge blockers never change the attack set. Enumerating the interior subsets
/// in ascending order produces exactly the indices returned by PEXT.
fn SliderTable(comptime diagonal: bool) type {
    return struct {
        const layout = blk: {
            @setEvalBranchQuota(80000);
            var result: struct { masks: [64]u64, offsets: [64]usize, len: usize } = undefined;
            result.len = 0;
            for (0..64) |i| {
                const s: Sq = @intCast(i);
                var mask: u64 = 0;
                const start = if (diagonal) 4 else 0;
                for (directions[start..][0..4]) |dir| {
                    var next = step(s, dir);
                    while (next) |dst| : (next = step(dst, dir)) {
                        if (step(dst, dir) != null) mask |= bit(dst);
                    }
                }
                result.masks[i] = mask;
                result.offsets[i] = result.len;
                result.len += @as(usize, 1) << @intCast(@popCount(mask));
            }
            break :blk result;
        };
        const table = blk: {
            @setEvalBranchQuota(16000000);
            var entries: [layout.len]u64 = undefined;
            for (0..64) |i| {
                const mask = layout.masks[i];
                var subset: u64 = 0;
                var index = layout.offsets[i];
                while (true) : (index += 1) {
                    entries[index] = rayAttacks(@intCast(i), subset, diagonal);
                    subset = (subset -% mask) & mask;
                    if (subset == 0) break;
                }
            }
            break :blk entries;
        };
    };
}

fn sliders(s: Sq, occ: u64, comptime diagonal: bool) u64 {
    const target = @import("builtin").target;
    if (comptime target.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(target.cpu.features, .bmi2)) {
        const lut = SliderTable(diagonal);
        const packed_bits = asm ("pextq %[mask], %[occ], %[index]"
            : [index] "=r" (-> u64),
            : [occ] "r" (occ),
              [mask] "r" (lut.layout.masks[s]),
        );
        return lut.table[lut.layout.offsets[s] + packed_bits];
    }
    return rayAttacks(s, occ, diagonal);
}

fn randomKey(n: u64) u64 {
    var z = n +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}
const keys = blk: {
    @setEvalBranchQuota(25000);
    var k: [794]u64 = undefined;
    for (&k, 0..) |*v, i| v.* = randomKey(i);
    break :blk k;
};
const turn_key = keys[793];
fn castleKey(rights: u4) u64 {
    return keys[768 + @as(usize, rights)];
}

fn classicalValue(p: u8, s: Sq) i32 {
    const rel = if (color(p) == 0) s else s ^ 56;
    const r: i32 = @intCast(rel / 8);
    const f: i32 = @intCast(rel % 8);
    const center = 14 - @as(i32, @intCast(@abs(2 * r - 7) + @abs(2 * f - 7)));
    const white: i32 = switch (kind(p)) {
        pawn => 100 + r * r * 2 + center,
        knight => 300 + 4 * center,
        bishop => 322 + 2 * center,
        rook => 500 + 2 * r + (if (r == 6) @as(i32, 14) else 0),
        queen => 920 + center,
        else => 0,
    };
    return if (color(p) == 0) white else -white;
}

pub const List = struct {
    moves: [Move.max_moves]Move = undefined,
    len: usize = 0,

    pub fn contains(self: *const List, move: Move) bool {
        for (self.moves[0..self.len]) |candidate| {
            if (bits(candidate) == bits(move)) return true;
        }
        return false;
    }

    pub fn findUci(self: *const List, notation: []const u8) ?Move {
        var buf: [5]u8 = undefined;
        for (self.moves[0..self.len]) |move| {
            if (std.mem.eql(u8, notation, uciName(move, &buf))) return move;
        }
        return null;
    }

    fn add(self: *List, a: Sq, b: Sq, typ: Move.Type, promo: u2) void {
        self.moves[self.len] = .{ .source = @fromBackingInt(a), .destination = @fromBackingInt(b), .move_type = typ, .promotion = @fromBackingInt(promo) };
        self.len += 1;
    }
    fn pawnMove(self: *List, a: Sq, b: Sq) void {
        if (b < 8 or b >= 56) {
            inline for (.{ 3, 0, 2, 1 }) |promo| self.add(a, b, .promotion, promo);
        } else self.add(a, b, .normal, 0);
    }
};

pub const Board = struct {
    squares: [64]u8 = @splat(0),
    pieces: [2][6]u64 = @splat(@splat(0)),
    occ: [2]u64 = .{ 0, 0 },
    side: u1 = 0,
    rights: u4 = 0,
    ep: u8 = empty_ep,
    halfmove: u16 = 0,
    hash: u64 = 0,
    pawn_hash: u64 = 0,
    nonpawn_hash: [2]u64 = .{ 0, 0 },
    classical: i32 = 0,
    layer: Layer = .{ .values = @splat(0) },
    acc: union { king: king_nnue.Acc, wide: wide_nnue.Acc } = .{ .king = .{} },
    material_cp: i32 = 0,
    phase_count: u8 = 0,
    pawn_scores: [3]i32 = @splat(0),

    pub fn fromPosition(pos: *const pollock.Position, net: ?*const Network) !Board {
        if (pos.chess960) return error.UnsupportedChess960;
        var b: Board = .{};
        if (net) |n| if (n.wide_net != null) {
            b.acc = .{ .wide = .{} };
        };
        b.rights = @bitCast(pos.info.castling_rights);
        b.side = @backingInt(pos.side_to_move);
        b.halfmove = @intCast(@min(pos.info.halfmove_clock, 65535));
        if (pos.info.en_passant_square) |s| b.ep = @backingInt(s);
        if (net) |n| for (&b.layer.values, n.hidden_bias) |*v, w| {
            v.* = w;
        };
        for (0..64) |i| {
            const sq: Sq = @intCast(i);
            if (pos.board.get(@fromBackingInt(sq))) |p| {
                if (net) |n| if (n.wide_net != null and @popCount(b.occupied()) == 32) return error.InvalidPieceCount;
                b.toggle(sq, piece(@backingInt(p.color), @backingInt(p.type)), true, net);
            }
        }
        if (@popCount(b.pieces[0][king]) != 1 or @popCount(b.pieces[1][king]) != 1) return error.InvalidKings;
        if (net) |n| {
            if (n.wide_net) |w| {
                inline for (0..2) |side| w.refresh(&b.acc.wide, side, @intCast(@ctz(b.pieces[side][king])), &b.squares);
            } else if (n.king_net) |k| {
                inline for (0..2) |side| k.refresh(&b.acc.king, side, @intCast(@ctz(b.pieces[side][king])), &b.squares);
                if (k.pawn_weights) |*weights| b.pawn_scores = pawn_terms.score(weights, b.pieces[0][pawn], b.pieces[1][pawn]);
            }
        }
        b.hash ^= castleKey(b.rights) ^ b.epKey();
        if (b.side != 0) b.hash ^= turn_key;
        return b;
    }

    inline fn toggle(self: *Board, s: Sq, p: u8, adding: bool, net: ?*const Network) void {
        const index = @as(usize, p - 1) * 64 + s;
        self.squares[s] = if (adding) p else 0;
        self.pieces[color(p)][kind(p)] ^= bit(s);
        self.occ[color(p)] ^= bit(s);
        self.hash ^= keys[index];
        if (kind(p) == pawn) {
            self.pawn_hash ^= keys[index];
        } else {
            self.nonpawn_hash[color(p)] ^= keys[index];
        }
        if (net) |n| {
            if (n.wide_net != null or n.king_net != null) {
                const mat = king_nnue.material[kind(p)] * (if (color(p) == 0) @as(i32, 1) else -1);
                self.material_cp += if (adding) mat else -mat;
                if (n.king_net) |k| {
                    const ph = king_nnue.phase_weight[kind(p)];
                    self.phase_count = if (adding) self.phase_count + ph else self.phase_count - ph;
                    k.update(&self.acc.king, p, s, adding);
                }
                return;
            }
            const old: @Vector(16, i32) = self.layer.values;
            const ws: @Vector(16, i16) = n.feature_weights[index];
            const w: @Vector(16, i32) = @intCast(ws);
            self.layer.values = if (adding) old + w else old - w;
        } else {
            const v = classicalValue(p, s);
            self.classical += if (adding) v else -v;
        }
    }

    pub inline fn occupied(self: *const Board) u64 {
        return self.occ[0] | self.occ[1];
    }

    fn attackedWith(self: *const Board, s: Sq, by: u1, occ: u64, exclude: u64) bool {
        const b = &self.pieces[by];
        return attacks.pawns[by ^ 1][s] & b[pawn] & ~exclude != 0 or
            attacks.knights[s] & b[knight] != 0 or attacks.kings[s] & b[king] != 0 or
            sliders(s, occ, true) & (b[bishop] | b[queen]) != 0 or
            sliders(s, occ, false) & (b[rook] | b[queen]) != 0;
    }

    pub fn inCheck(self: *const Board) bool {
        return self.attackedWith(@intCast(@ctz(self.pieces[self.side][king])), self.side ^ 1, self.occupied(), 0);
    }

    pub fn hasLegal(self: *const Board) bool {
        const us = self.side;
        const them = us ^ 1;
        const king_square: Sq = @intCast(@ctz(self.pieces[us][king]));
        const occupancy = self.occupied() & ~bit(king_square);
        var escapes = attacks.kings[king_square] & ~(self.occ[us] | self.pieces[them][king]);
        while (escapes != 0) {
            const target = pop(&escapes);
            if (!self.attackedWith(target, them, occupancy, 0)) return true;
        }
        var moves: List = .{};
        self.generate(false, &moves);
        for (moves.moves[0..moves.len]) |m| {
            if (self.child(m, null) != null) return true;
        }
        return false;
    }

    fn epKey(self: *const Board) u64 {
        if (self.ep >= 64) return 0;
        const dst: Sq = @intCast(self.ep);
        const captured: Sq = dst ^ 8;
        if (self.squares[captured] != piece(self.side ^ 1, pawn) or self.squares[dst] != 0) return 0;
        var candidates = attacks.pawns[self.side ^ 1][dst] & self.pieces[self.side][pawn];
        const k: Sq = @intCast(@ctz(self.pieces[self.side][king]));
        while (candidates != 0) {
            const a = pop(&candidates);
            const occ = (self.occupied() & ~bit(a) & ~bit(captured)) | bit(dst);
            if (!self.attackedWith(k, self.side ^ 1, occ, bit(captured))) return keys[784 + @as(usize, dst % 8)];
        }
        return 0;
    }

    pub fn generate(self: *const Board, tactical_only: bool, list: *List) void {
        list.len = 0;
        const us = self.side;
        const them = us ^ 1;
        const occ = self.occupied();
        const enemy = self.occ[them] & ~self.pieces[them][king];
        const targets = if (tactical_only) enemy else (~self.occ[us] & ~self.pieces[them][king]);
        const forward: i8 = if (us == 0) 8 else -8;
        var pawns = self.pieces[us][pawn];
        while (pawns != 0) {
            const a = pop(&pawns);
            const one_i = @as(i8, a) + forward;
            if (one_i < 0 or one_i >= 64) continue;
            const one: Sq = @intCast(one_i);
            if (self.squares[one] == 0 and (!tactical_only or one < 8 or one >= 56)) {
                list.pawnMove(a, one);
                if (!tactical_only and a / 8 == (if (us == 0) @as(u6, 1) else 6)) {
                    const two: Sq = @intCast(one_i + forward);
                    if (self.squares[two] == 0) list.add(a, two, .normal, 0);
                }
            }
            var caps = attacks.pawns[us][a] & enemy;
            while (caps != 0) list.pawnMove(a, pop(&caps));
            if (self.ep < 64) {
                const dst: Sq = @intCast(self.ep);
                if (attacks.pawns[us][a] & bit(dst) != 0 and self.squares[dst] == 0 and self.squares[dst ^ 8] == piece(them, pawn))
                    list.add(a, dst, .en_passant, 0);
            }
        }
        inline for (.{ knight, bishop, rook, queen, king }) |k| {
            var men = self.pieces[us][k];
            while (men != 0) {
                const a = pop(&men);
                var dests = targets & switch (k) {
                    knight => attacks.knights[a],
                    bishop => sliders(a, occ, true),
                    rook => sliders(a, occ, false),
                    queen => sliders(a, occ, true) | sliders(a, occ, false),
                    king => attacks.kings[a],
                    else => unreachable,
                };
                while (dests != 0) list.add(a, pop(&dests), .normal, 0);
            }
        }
        if (tactical_only) return;
        const base: Sq = if (us == 0) 0 else 56;
        const k = base + 4;
        if (self.squares[k] != piece(us, king)) return;
        inline for (.{ true, false }) |short| {
            const mask: u4 = if (short) 1 else 2;
            const rights_mask = mask << (@as(u2, us) * 2);
            const rook_sq = base + (if (short) @as(Sq, 7) else 0);
            const middle = base + (if (short) @as(Sq, 5) else 3);
            const dest = base + (if (short) @as(Sq, 6) else 2);
            if (self.rights & rights_mask != 0 and self.squares[rook_sq] == piece(us, rook) and
                self.squares[middle] == 0 and self.squares[dest] == 0 and (short or self.squares[base + 1] == 0) and
                !self.attackedWith(k, them, occ, 0) and !self.attackedWith(middle, them, occ & ~bit(k), 0))
                list.add(k, dest, .castle, 0);
        }
    }

    fn keepRights(s: Sq) u4 {
        return switch (s) {
            0 => 13,
            4 => 12,
            7 => 14,
            56 => 7,
            60 => 3,
            63 => 11,
            else => 15,
        };
    }

    pub fn child(self: *const Board, m: Move, net: ?*const Network) ?Board {
        var b = self.*;
        const a = from(m);
        const dst = to(m);
        const us = b.side;
        const moving = b.squares[a];
        const cap = if (m.move_type == .en_passant) dst ^ 8 else dst;
        const taken = b.squares[cap];
        b.hash ^= castleKey(b.rights) ^ b.epKey() ^ turn_key;
        b.ep = empty_ep;
        b.rights &= keepRights(a) & keepRights(dst);
        b.halfmove = if (kind(moving) == pawn or taken != 0) 0 else b.halfmove +| 1;
        if (taken != 0) b.toggle(cap, taken, false, net);
        b.toggle(a, moving, false, net);
        const placed = if (m.move_type == .promotion) piece(us, @backingInt(m.promotionPieceType())) else moving;
        b.toggle(dst, placed, true, net);
        if (m.move_type == .castle) {
            const rfrom = if (dst > a) a + 3 else a - 4;
            const rto = if (dst > a) a + 1 else a - 1;
            b.toggle(rfrom, piece(us, rook), false, net);
            b.toggle(rto, piece(us, rook), true, net);
        }
        if (kind(moving) == pawn and (dst ^ a) == 16) b.ep = @intCast((@as(u7, a) + dst) / 2);
        if (b.inCheck()) return null;
        if (net) |n| {
            if (n.wide_net) |w| {
                w.advance(&self.acc.wide, &b.acc.wide, us, .{
                    .from = a,
                    .to = dst,
                    .moving = moving,
                    .placed = placed,
                    .taken = taken,
                    .capture_square = cap,
                    .king_move = kind(moving) == king,
                    .castle = m.move_type == .castle,
                }, &b.squares);
            } else if (n.king_net) |k| {
                if (kind(moving) == king and !std.meta.eql(b.acc.king.frames[us], king_nnue.Frame.init(dst, us))) {
                    k.refresh(&b.acc.king, us, dst, &b.squares);
                }
            }
        }
        if (kind(moving) == pawn or (taken != 0 and kind(taken) == pawn)) {
            if (net) |n| if (n.king_net) |k| {
                if (k.pawn_weights) |*weights| b.pawn_scores = pawn_terms.score(weights, b.pieces[0][pawn], b.pieces[1][pawn]);
            };
        }
        b.side ^= 1;
        b.hash ^= castleKey(b.rights) ^ b.epKey();
        return b;
    }

    pub fn nullChild(self: *const Board) Board {
        var b = self.*;
        b.hash ^= b.epKey() ^ turn_key;
        b.ep = empty_ep;
        b.side ^= 1;
        b.halfmove = 0;
        return b;
    }

    pub fn kingScore(self: *const Board, net: *const king_nnue.Network) i32 {
        return self.kingScoreFor(net, self.side);
    }

    fn kingScoreFor(self: *const Board, net: *const king_nnue.Network, side: u1) i32 {
        const phase = king_nnue.Network.phaseIndex(self.phase_count);
        return net.score(&self.acc.king, self.material_cp + self.pawn_scores[phase], self.phase_count, side);
    }

    pub fn neuralScore(self: *const Board, n: *const Network) i32 {
        return self.neuralScoreFor(n, self.side);
    }

    pub fn neuralScoreFor(self: *const Board, n: *const Network, side: u1) i32 {
        if (n.wide_net) |w| return w.score(&self.acc.wide, self.material_cp, @popCount(self.occupied()), side);
        return self.kingScoreFor(n.king_net.?, side);
    }

    pub fn evaluate(self: *const Board, net: ?*const Network) i32 {
        if (net) |n| if (n.king_net != null or n.wide_net != null) return std.math.clamp(self.neuralScore(n), -20000, 20000);
        const score: i32 = if (net) |n| blk: {
            const raw = n.score(&self.layer, @fromBackingInt(self.side));
            const cp = if (n.score_unit == .centipawns) raw else @divTrunc(raw, 2);
            break :blk @intCast(std.math.clamp(cp, -20000, 20000));
        } else if (self.side == 0) self.classical else -self.classical;
        return score + 9;
    }

    pub fn insufficient(self: *const Board) bool {
        if (self.pieces[0][pawn] | self.pieces[1][pawn] | self.pieces[0][rook] | self.pieces[1][rook] | self.pieces[0][queen] | self.pieces[1][queen] != 0) return false;
        const bishops = self.pieces[0][bishop] | self.pieces[1][bishop];
        const knights = self.pieces[0][knight] | self.pieces[1][knight];
        if (@popCount(bishops | knights) <= 1) return true;
        const light: u64 = 0x55aa55aa55aa55aa;
        return knights == 0 and (bishops & light == 0 or bishops & ~light == 0);
    }

    pub fn victim(self: *const Board, m: Move) i32 {
        if (m.move_type == .en_passant) return 100;
        const p = self.squares[to(m)];
        return if (p == 0) 0 else values[kind(p)];
    }

    fn attackers(self: *const Board, s: Sq, by: u1, occ: u64) u64 {
        const b = &self.pieces[by];
        return occ & ((attacks.pawns[by ^ 1][s] & b[pawn]) | (attacks.knights[s] & b[knight]) |
            (attacks.kings[s] & b[king]) | (sliders(s, occ, true) & (b[bishop] | b[queen])) |
            (sliders(s, occ, false) & (b[rook] | b[queen])));
    }

    // Material balance of alternating least-valuable captures on the destination.
    pub fn exchange(self: *const Board, m: Move) i32 {
        const dst = to(m);
        var occ = self.occupied() & ~bit(from(m));
        if (m.move_type == .en_passant) occ &= ~bit(dst ^ 8);
        var worth = values[kind(self.squares[from(m)])];
        var gains: [32]i32 = undefined;
        gains[0] = self.victim(m);
        if (m.move_type == .promotion) {
            worth = values[@backingInt(m.promotionPieceType())];
            gains[0] += worth - 100;
        }
        var depth: usize = 0;
        var side = self.side ^ 1;
        while (depth + 1 < gains.len) : (side ^= 1) {
            const available = self.attackers(dst, side, occ);
            if (available == 0) break;
            var cheapest: usize = pawn;
            while (available & self.pieces[side][cheapest] == 0) cheapest += 1;
            const sq: Sq = @intCast(@ctz(available & self.pieces[side][cheapest]));
            occ &= ~bit(sq);
            if (cheapest == king and self.attackers(dst, side ^ 1, occ) != 0) break;
            depth += 1;
            gains[depth] = worth - gains[depth - 1];
            worth = values[cheapest];
            if (cheapest == pawn and (dst < 8 or dst >= 56)) {
                gains[depth] += values[queen] - 100;
                worth = values[queen];
            }
        }
        while (depth > 0) : (depth -= 1) gains[depth - 1] = @min(gains[depth - 1], -gains[depth]);
        return gains[0];
    }

    pub fn nonPawn(self: *const Board) bool {
        return self.occ[self.side] & ~(self.pieces[self.side][pawn] | self.pieces[self.side][king]) != 0;
    }
};

pub fn uciName(m: Move, buf: *[5]u8) []const u8 {
    const a = from(m);
    const b = to(m);
    buf.* = .{ 'a' + @as(u8, a % 8), '1' + @as(u8, a / 8), 'a' + @as(u8, b % 8), '1' + @as(u8, b / 8), m.promotionChar() };
    return buf[0..if (m.move_type == .promotion) @as(usize, 5) else 4];
}

pub fn playUci(b: *const Board, notation: []const u8, net: ?*const Network) ?Board {
    var list: List = .{};
    b.generate(false, &list);
    return b.child(list.findUci(notation) orelse return null, net);
}

pub fn perft(b: *const Board, depth: u8) u64 {
    if (depth == 0) return 1;
    var list: List = .{};
    b.generate(false, &list);
    var nodes: u64 = 0;
    for (list.moves[0..list.len]) |m| {
        const next = b.child(m, null) orelse continue;
        nodes += perft(&next, depth - 1);
    }
    return nodes;
}
