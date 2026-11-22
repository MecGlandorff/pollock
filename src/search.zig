//! Iterative deepening, principal-variation search, and capture search for standard chess.
const std = @import("std");
const mg = @import("move_generation.zig");
const Move = mg.Move;
const Board = mg.Board;
const Network = mg.Network;

const max_ply = 96;
const history_len = 128;
pub const mate: i32 = 30000;
const infinity: i32 = 31000;

const reductions = blk: {
    @setEvalBranchQuota(1000000);
    var result = std.mem.zeroes([64][64]u8);
    for (2..64) |depth| {
        for (2..64) |move| {
            const d: f64 = @floatFromInt(depth);
            const m: f64 = @floatFromInt(move);
            result[depth][move] = @intFromFloat(0.55 + @log(d) * @log(m) / 2.25);
        }
    }
    break :blk result;
};

const Bound = enum(u8) { empty, exact, lower, upper };
pub const Entry = struct {
    key: u64 = 0,
    move: Move = .{},
    score: i16 = 0,
    depth: i8 = -1,
    bound: Bound = .empty,
    age: u8 = 0,
    halfmove: u8 = 0,
};
pub const Limits = struct {
    /// Optional root move restriction. The caller owns the list until run returns.
    root_moves: ?*const mg.List = null,
    depth: u8 = 80,
    nodes: u64 = std.math.maxInt(u64),
    soft_ms: i64 = std.math.maxInt(i64),
    hard_ms: i64 = std.math.maxInt(i64),
};
pub const Result = struct {
    best: ?Move = null,
    score: i32 = 0,
    nodes: u64 = 0,
    depth: u8 = 0,
    elapsed: i64 = 0,
};

pub fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn toTable(score: i32, ply: usize) i16 {
    const distance: i32 = @intCast(ply);
    return @intCast(if (score > mate - max_ply) score + distance else if (score < -mate + max_ply) score - distance else score);
}
fn fromTable(value: i16, ply: usize) i32 {
    const score: i32 = value;
    const distance: i32 = @intCast(ply);
    return if (score > mate - max_ply) score - distance else if (score < -mate + max_ply) score + distance else score;
}

pub const Engine = struct {
    io: std.Io,
    table: []Entry,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    history: [2][64][64]i16 = @splat(@splat(@splat(0))),
    killers: [max_ply][2]Move = @splat(.{ .{}, .{} }),
    correction: [2][3][8192]i16 = @splat(@splat(@splat(0))),
    age: u8 = 0,

    pub fn reset(self: *Engine) void {
        @memset(self.table, .{});
        self.history = @splat(@splat(@splat(0)));
        self.correction = @splat(@splat(@splat(0)));
        self.killers = @splat(.{ .{}, .{} });
    }

    pub fn run(self: *Engine, board: Board, net: ?*const Network, previous: []const u64, limits: Limits) Result {
        self.age +%= 1;
        self.killers = @splat(.{ .{}, .{} });
        var ctx = Context{ .engine = self, .net = net, .limits = limits, .start = now(self.io) };
        const count = @min(previous.len, history_len);
        @memcpy(ctx.path[0..count], previous[previous.len - count ..]);
        ctx.root_at = count;
        ctx.path[count] = board.hash;
        board.generate(false, &ctx.root_moves);
        if (limits.root_moves) |allowed| {
            var kept: usize = 0;
            for (ctx.root_moves.moves[0..ctx.root_moves.len]) |move| {
                if (allowed.contains(move)) {
                    ctx.root_moves.moves[kept] = move;
                    kept += 1;
                }
            }
            ctx.root_moves.len = kept;
        }
        var result: Result = .{};
        for (ctx.root_moves.moves[0..ctx.root_moves.len]) |m| {
            if (board.child(m, net) != null) {
                result.best = m;
                break;
            }
        }
        if (result.best == null) {
            result.score = if (board.inCheck() and (limits.root_moves == null or !board.hasLegal())) -mate else 0;
            return result;
        }
        var depth: u8 = 1;
        while (depth <= @min(limits.depth, max_ply - 2)) : (depth += 1) {
            ctx.root_best = result.best.?;
            var window: i32 = if (depth >= 5) 35 else infinity;
            var lo = @max(-infinity, result.score - window);
            var hi = @min(infinity, result.score + window);
            var score: i32 = 0;
            while (true) {
                score = ctx.search(&board, depth, lo, hi, 0, true);
                if (ctx.aborted or (score > lo and score < hi)) break;
                window = @min(infinity, window * 3);
                if (score <= lo) lo = @max(-infinity, score - window);
                if (score >= hi) hi = @min(infinity, score + window);
            }
            if (ctx.aborted) break;
            result.best = ctx.root_best;
            result.score = score;
            result.depth = depth;
            const elapsed = now(self.io) - ctx.start;
            if (elapsed >= limits.soft_ms or score >= mate - @as(i32, depth)) break;
        }
        result.nodes = ctx.nodes;
        result.elapsed = now(self.io) - ctx.start;
        return result;
    }
};

const Context = struct {
    engine: *Engine,
    net: ?*const Network,
    limits: Limits,
    start: i64,
    nodes: u64 = 0,
    aborted: bool = false,
    path: [history_len + max_ply + 1]u64 = undefined,
    root_at: usize = 0,
    root_best: Move = .{},
    root_moves: mg.List = .{},

    fn visit(self: *Context) bool {
        self.nodes += 1;
        if (self.nodes >= self.limits.nodes or self.engine.stop.load(.monotonic) or
            ((self.nodes & 255) == 0 and now(self.engine.io) - self.start >= self.limits.hard_ms))
            self.aborted = true;
        return self.aborted;
    }

    fn drawn(self: *Context, b: *const Board, ply: usize) bool {
        if (b.insufficient()) return true;
        const idx = self.root_at + ply;
        self.path[idx] = b.hash;
        if (b.halfmove >= 100) return true;
        const first = idx -| @as(usize, b.halfmove);
        var n = idx;
        var previous_matches: u8 = 0;
        while (n >= first + 2) {
            n -= 2;
            if (self.path[n] != b.hash) continue;
            previous_matches += 1;
            if (n >= self.root_at or previous_matches == 2) return true;
        }
        return false;
    }

    fn scoreMove(self: *Context, b: *const Board, m: Move, tt: Move, ply: usize) i32 {
        if (mg.bits(m) == mg.bits(tt)) return 1000000;
        const captured = b.victim(m);
        if (captured != 0 or m.move_type == .promotion) {
            const attacker = mg.values[mg.kind(b.squares[mg.from(m)])];
            const bonus: i32 = if (m.move_type == .promotion) mg.values[@backingInt(m.promotionPieceType())] else 0;
            const winning = bonus != 0 or attacker <= captured or b.exchange(m) >= 0;
            return (if (winning) @as(i32, 70000) else -25000) + 12 * captured - @divTrunc(attacker, 16) + bonus;
        }
        if (mg.bits(m) == mg.bits(self.engine.killers[ply][0])) return 45000;
        if (mg.bits(m) == mg.bits(self.engine.killers[ply][1])) return 44000;
        return self.engine.history[b.side][mg.from(m)][mg.to(m)];
    }

    fn order(self: *Context, b: *const Board, list: *const mg.List, tt: Move, ply: usize, scores: *[256]i32) void {
        for (list.moves[0..list.len], scores[0..list.len]) |m, *score| score.* = self.scoreMove(b, m, tt, ply);
    }

    fn pick(list: *mg.List, scores: *[256]i32, i: usize) Move {
        var best = i;
        for (i + 1..list.len) |j| if (scores[j] > scores[best]) {
            best = j;
        };
        std.mem.swap(i32, &scores[i], &scores[best]);
        std.mem.swap(Move, &list.moves[i], &list.moves[best]);
        return list.moves[i];
    }

    fn reward(self: *Context, side: u1, m: Move, bonus: i32) void {
        const hist = &self.engine.history[side][mg.from(m)][mg.to(m)];
        const value = @as(i32, hist.*) + bonus - @divTrunc(@as(i32, hist.*) * @as(i32, @intCast(@abs(bonus))), 16384);
        hist.* = @intCast(std.math.clamp(value, -16384, 16384));
    }

    fn correctionKeys(b: *const Board) [3]usize {
        return .{ @as(usize, @truncate(b.pawn_hash)) & 8191, @as(usize, @truncate(b.nonpawn_hash[0])) & 8191, @as(usize, @truncate(b.nonpawn_hash[1])) & 8191 };
    }

    fn adjusted(self: *Context, b: *const Board, raw: i32) i32 {
        const keys = correctionKeys(b);
        const values = &self.engine.correction[b.side];
        const total = 2 * @as(i32, values[0][keys[0]]) + @as(i32, values[1][keys[1]]) + values[2][keys[2]];
        return raw + @divTrunc(total, 256);
    }

    fn learnCorrection(self: *Context, b: *const Board, depth: i32, error_cp: i32) void {
        const target = std.math.clamp(error_cp, -200, 200) * 64;
        const weight = @min(16, depth + 1);
        const keys = correctionKeys(b);
        inline for (0..3) |i| {
            const entry = &self.engine.correction[b.side][i][keys[i]];
            entry.* = @intCast(@as(i32, entry.*) + @divTrunc((target - entry.*) * weight, 64));
        }
    }

    fn tableEntry(self: *Context, key: u64) *Entry {
        return &self.engine.table[@as(usize, @truncate(key)) & (self.engine.table.len - 1)];
    }

    fn cutoff(entry: Entry, b: *const Board, depth: i32, alpha: i32, beta: i32, ply: usize) ?i32 {
        if (entry.key != b.hash or entry.bound == .empty or entry.depth < depth) return null;
        if (@max(b.halfmove, entry.halfmove) >= 80 and b.halfmove != entry.halfmove) return null;
        const score = fromTable(entry.score, ply);
        if (entry.bound == .exact or (entry.bound == .lower and score >= beta) or
            (entry.bound == .upper and score <= alpha)) return score;
        return null;
    }

    fn saveQuietBound(self: *Context, slot: *Entry, b: *const Board, best_move: Move, score: i32, bound: Bound, ply: usize) void {
        if (slot.bound != .empty and slot.depth > 0 and (slot.key == b.hash or slot.age == self.engine.age)) return;
        slot.* = .{
            .key = b.hash,
            .move = best_move,
            .score = toTable(score, ply),
            .depth = 0,
            .bound = bound,
            .age = self.engine.age,
            .halfmove = @intCast(@min(b.halfmove, 255)),
        };
    }

    fn quiescence(self: *Context, b: *const Board, alpha_in: i32, beta: i32, ply: usize) i32 {
        if (self.visit()) return 0;
        if (ply >= max_ply - 1) return b.evaluate(self.net);
        const checked = b.inCheck();
        if (self.drawn(b, ply)) {
            if (checked and !b.hasLegal()) return -mate + @as(i32, @intCast(ply));
            return 0;
        }
        const slot = self.tableEntry(b.hash);
        const cached = slot.*;
        if (beta - alpha_in == 1) {
            if (cutoff(cached, b, 0, alpha_in, beta, ply)) |score| return score;
        }
        var alpha = alpha_in;
        var best_move: Move = .{};
        const stand = self.adjusted(b, b.evaluate(self.net));
        if (!checked) {
            if (stand >= beta) return if (b.hasLegal()) stand else 0;
            alpha = @max(alpha, stand);
        }
        var list: mg.List = .{};
        b.generate(!checked, &list);
        var scores: [256]i32 = undefined;
        self.order(b, &list, if (cached.key == b.hash) cached.move else .{}, ply, &scores);
        var legal = false;
        for (0..list.len) |i| {
            const m = pick(&list, &scores, i);
            const child = b.child(m, self.net) orelse continue;
            legal = true;
            if (!checked and m.move_type != .promotion and !child.inCheck()) {
                if (stand + b.victim(m) + 160 < alpha or b.exchange(m) < -75) continue;
            }
            const score = -self.quiescence(&child, -beta, -alpha, ply + 1);
            if (self.aborted) return 0;
            if (score >= beta) {
                self.saveQuietBound(slot, b, m, score, .lower, ply);
                return score;
            }
            if (score > alpha) {
                alpha = score;
                best_move = m;
            }
        }
        if (!legal) {
            if (checked) return -mate + @as(i32, @intCast(ply));
            if (!b.hasLegal()) return 0;
        }
        self.saveQuietBound(slot, b, best_move, alpha, if (alpha > alpha_in) .exact else .upper, ply);
        return alpha;
    }

    fn search(self: *Context, b: *const Board, depth_in: i32, alpha_in: i32, beta_in: i32, ply: usize, allow_null: bool) i32 {
        if (depth_in <= 0) return self.quiescence(b, alpha_in, beta_in, ply);
        if (self.visit()) return 0;
        if (ply >= max_ply - 1) return b.evaluate(self.net);
        const checked = b.inCheck();
        if (ply > 0 and self.drawn(b, ply)) {
            if (checked and !b.hasLegal()) return -mate + @as(i32, @intCast(ply));
            return 0;
        }
        const distance: i32 = @intCast(ply);
        var alpha = @max(alpha_in, -mate + distance);
        const original = alpha;
        const beta = @min(beta_in, mate - distance - 1);
        if (alpha >= beta) return alpha;
        const depth = depth_in + @as(i32, @intFromBool(checked and ply < 32));
        const pv = beta - alpha > 1;
        const slot = self.tableEntry(b.hash);
        const cached = slot.*;
        var tt_move: Move = .{};
        if (cached.bound != .empty and cached.key == b.hash) {
            tt_move = cached.move;
            if (ply > 0 and !pv) {
                if (cutoff(cached, b, depth, alpha, beta, ply)) |score| return score;
            }
        }
        if (ply == 0) tt_move = self.root_best;
        const raw = b.evaluate(self.net);
        const static = self.adjusted(b, raw);
        if (ply > 0 and !pv and !checked and @abs(beta) < mate - max_ply) {
            if (depth <= 5 and static - 85 * depth >= beta and b.hasLegal()) return static;
            if (allow_null and depth >= 3 and static >= beta and b.nonPawn()) {
                const child = b.nullChild();
                const score = -self.search(&child, depth - 3 - @divTrunc(depth, 4), -beta, -beta + 1, ply + 1, false);
                if (self.aborted) return 0;
                if (score >= beta and b.hasLegal()) return beta;
            }
        }
        var list: mg.List = .{};
        if (ply == 0) {
            list = self.root_moves;
        } else {
            b.generate(false, &list);
        }
        var scores: [256]i32 = undefined;
        self.order(b, &list, tt_move, ply, &scores);
        var count: usize = 0;
        var best: i32 = -infinity;
        var best_move: Move = .{};
        var quiets: [256]Move = undefined;
        var quiet_count: usize = 0;
        for (0..list.len) |i| {
            const m = pick(&list, &scores, i);
            const child = b.child(m, self.net) orelse continue;
            count += 1;
            const quiet = b.victim(m) == 0 and m.move_type != .promotion;
            const gives_check = child.inCheck();
            if (count > 1 and !pv and !checked and !gives_check and best > -mate + max_ply and m.move_type != .promotion) {
                if (quiet and depth <= 3 and count > @as(usize, @intCast(3 + depth * depth)) and static + 90 * depth < alpha) continue;
                if (depth <= 4 and scores[i] < 0 and b.exchange(m) < -90 * depth) continue;
            }
            const remaining = depth - 1;
            var score: i32 = 0;
            if (count == 1) {
                score = -self.search(&child, remaining, -beta, -alpha, ply + 1, true);
            } else {
                var reduction: i32 = 0;
                if (depth >= 3 and count >= 4 and quiet and !checked and !gives_check and scores[i] < 44000) {
                    reduction = reductions[@intCast(@min(depth, 63))][@min(count, 63)];
                    if (!pv) reduction += 1;
                    reduction -= @divTrunc(@as(i32, self.engine.history[b.side][mg.from(m)][mg.to(m)]), 6000);
                    reduction = std.math.clamp(reduction, 0, remaining - 1);
                }
                score = -self.search(&child, remaining - reduction, -alpha - 1, -alpha, ply + 1, true);
                if (score > alpha and reduction > 0) score = -self.search(&child, remaining, -alpha - 1, -alpha, ply + 1, true);
                if (pv and score > alpha and score < beta) score = -self.search(&child, remaining, -beta, -alpha, ply + 1, true);
            }
            if (self.aborted) return 0;
            if (score > best) {
                best = score;
                best_move = m;
                if (ply == 0) self.root_best = m;
            }
            alpha = @max(alpha, score);
            if (alpha >= beta) {
                if (quiet) {
                    if (mg.bits(m) != mg.bits(self.engine.killers[ply][0])) {
                        self.engine.killers[ply][1] = self.engine.killers[ply][0];
                        self.engine.killers[ply][0] = m;
                    }
                    const bonus = @min(1200, 30 * depth * depth);
                    self.reward(b.side, m, bonus);
                    for (quiets[0..quiet_count]) |q| self.reward(b.side, q, -@divTrunc(bonus, 2));
                }
                break;
            }
            if (quiet) {
                quiets[quiet_count] = m;
                quiet_count += 1;
            }
        }
        if (count == 0) return if (checked) -mate + distance else 0;
        // A restricted root score does not bound the unrestricted position.
        if (ply == 0 and self.limits.root_moves != null) return best;
        if (!checked and b.victim(best_move) == 0 and best_move.move_type != .promotion and @abs(best) < mate - max_ply and
            (best < beta or best > static) and (best > original or best < static))
        {
            self.learnCorrection(b, depth, best - raw);
        }
        if (slot.key == b.hash or slot.age != self.engine.age or slot.depth <= depth + 2) {
            slot.* = .{
                .key = b.hash,
                .move = best_move,
                .score = toTable(best, ply),
                .depth = @intCast(@min(depth, 120)),
                .bound = if (best >= beta) .lower else if (best <= original) .upper else .exact,
                .age = self.engine.age,
                .halfmove = @intCast(@min(b.halfmove, 255)),
            };
        }
        return best;
    }
};
