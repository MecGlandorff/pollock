//! Iterative deepening, principal-variation search, and capture search for standard chess.
const std = @import("std");
const p = @import("pollock");
const ev = @import("board_eval.zig");
const Move = p.Move;
const Position = p.Position;
const Network = p.wide_nnue.Network;
const bitboard = p.bitboard;

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
    root_moves: ?[]const Move = null,
    depth: u8 = 80,
    nodes: u64 = std.math.maxInt(u64),
    soft_ms: i64 = std.math.maxInt(i64),
    hard_ms: i64 = std.math.maxInt(i64),
    adapt_game_clock: bool = false,
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

const values = [_]i32{ 100, 325, 330, 500, 950, 20000 };

fn destination(m: Move) p.Square {
    if (m.kind != .castle) return m.destination;
    return .fromCoords(if (m.source.less(m.destination)) .g else .c, m.source.rank());
}

fn victim(b: *const Position, m: Move) i32 {
    if (m.kind == .castle) return 0;
    if (m.kind == .en_passant) return values[@backingInt(p.Piece.Type.pawn)];
    return if (b.onSquare(m.destination)) |piece| values[@backingInt(piece.type)] else 0;
}

fn allMoves(b: *Position, storage: *[Move.max_moves]Move) []Move {
    var list: p.movegen.MoveList = .initBuffer(storage);
    p.movegen.generateLegalMoves(b, &list, .all);
    return list.items;
}

fn tacticalMoves(b: *Position, storage: *[Move.max_moves]Move) []Move {
    var list: p.movegen.MoveList = .initBuffer(storage);
    if (b.checkers() != bitboard.empty) {
        p.movegen.generateLegalMoves(b, &list, .evasions);
    } else {
        p.movegen.generateLegalMoves(b, &list, .captures);
        // The reference qsearch also searches quiet underpromotions. Each legal
        // queen push from Pieter supplies the source and destination for all three.
        if (b.pieceOccupancy(b.sideToMove(), .pawn) & p.Rank.@"7".relative(b.sideToMove()).bitboard() != 0) {
            for (list.items) |m| {
                if (m.kind != .promotion or m.promotion_piece != .queen or b.onSquare(m.destination) != null) continue;
                for ([_]Move.Promotion{ .knight, .rook, .bishop }) |piece|
                    list.appendAssumeCapacity(.promotion(m.source, m.destination, piece));
            }
        }
    }
    return list.items;
}

fn hasLegal(b: *Position) bool {
    const us = b.sideToMove();
    const escapes = bitboard.baseAttacks(.king, b.kingSquare(us)) & ~b.colorOccupancy(us);
    if (escapes & ~b.allThreats() != 0) return true;
    var storage: [Move.max_moves]Move = undefined;
    return allMoves(b, &storage).len != 0;
}

fn insufficient(b: *const Position) bool {
    if (b.typeOccupancy(.pawn) | b.typeOccupancy(.rook) | b.typeOccupancy(.queen) != 0) return false;
    const bishops = b.typeOccupancy(.bishop);
    const knights = b.typeOccupancy(.knight);
    if (@popCount(bishops | knights) <= 1) return true;
    const light: u64 = 0x55aa55aa55aa55aa;
    return knights == 0 and (bishops & light == 0 or bishops & ~light == 0);
}

fn attackers(b: *const Position, square: p.Square, side: p.Color, occ: u64) u64 {
    const bishop, const rook = bitboard.bishopRookAttacks(square, occ);
    return occ & b.colorOccupancy(side) & ((bitboard.baseAttacks(.forPawn(side.opposite()), square) & b.typeOccupancy(.pawn)) |
        (bitboard.baseAttacks(.knight, square) & b.typeOccupancy(.knight)) |
        (bitboard.baseAttacks(.king, square) & b.typeOccupancy(.king)) |
        (bishop & (b.typeOccupancy(.bishop) | b.typeOccupancy(.queen))) |
        (rook & (b.typeOccupancy(.rook) | b.typeOccupancy(.queen))));
}

fn exchange(b: *const Position, m: Move) i32 {
    if (m.kind == .castle) return 0;
    const dst = m.destination;
    var occ = b.totalOccupancy() & ~m.source.bitboard();
    if (m.kind == .en_passant) occ &= ~p.Square.fromCoords(dst.file(), m.source.rank()).bitboard();
    var worth = values[@backingInt(b.onSquare(m.source).?.type)];
    var gains: [32]i32 = undefined;
    gains[0] = victim(b, m);
    if (m.kind == .promotion) {
        worth = values[@backingInt(m.promotionType())];
        gains[0] += worth - 100;
    }
    var depth: usize = 0;
    var side = b.sideToMove().opposite();
    while (depth + 1 < gains.len) : (side = side.opposite()) {
        const available = attackers(b, dst, side, occ);
        if (available == 0) break;
        const cheapest = for (std.enums.values(p.Piece.Type)) |pt| {
            if (available & b.typeOccupancy(pt) != 0) break pt;
        } else unreachable;
        const sq = bitboard.lsb(available & b.typeOccupancy(cheapest));
        occ &= ~sq.bitboard();
        if (cheapest == .king and attackers(b, dst, side.opposite(), occ) != 0) break;
        depth += 1;
        gains[depth] = worth - gains[depth - 1];
        worth = values[@backingInt(cheapest)];
        if (cheapest == .pawn and (dst.rank() == .@"1" or dst.rank() == .@"8")) {
            gains[depth] += values[@backingInt(p.Piece.Type.queen)] - 100;
            worth = values[@backingInt(p.Piece.Type.queen)];
        }
    }
    while (depth > 0) : (depth -= 1) gains[depth - 1] = @min(gains[depth - 1], -gains[depth]);
    return gains[0];
}

// Keep the reference search's pawn and per-colour nonpawn correction slots.
// Each entry is the low 13 bits of the original piece-square SplitMix64 key.
const correction_squares = blk: {
    @setEvalBranchQuota(10_000);
    var table: [2][6][64]u13 = undefined;
    for (&table, 0..) |*side, color| {
        for (side, 0..) |*row, kind| {
            for (row, 0..) |*key, sq| {
                var z: u64 = (color * 6 + kind) * 64 + sq +% 0x9e3779b97f4a7c15;
                z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
                z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
                key.* = @truncate(z ^ (z >> 31));
            }
        }
    }
    break :blk table;
};

const Node = struct {
    acc: ev.Acc,
    keys: [3]u13,

    fn toggle(keys: *[3]u13, piece: p.Piece, sq: p.Square) void {
        const color: usize = @backingInt(piece.color);
        const i = if (piece.type == .pawn) 0 else 1 + color;
        keys[i] ^= correction_squares[color][@backingInt(piece.type)][@backingInt(sq)];
    }

    fn root(b: *const Position, cache: *ev.FrameCache) Node {
        var result = Node{ .acc = ev.refreshCached(b, cache), .keys = .{ 0, 0, 0 } };
        var occupied = b.totalOccupancy();
        while (occupied != 0) {
            const sq = bitboard.popLsb(&occupied);
            toggle(&result.keys, b.onSquare(sq).?, sq);
        }
        return result;
    }

    fn afterInto(self: *const Node, b: *const Position, m: Move, cache: *ev.FrameCache, child: *Node) void {
        const change = ev.Change.after(b, m);
        var keys = self.keys;
        toggle(&keys, change.moving, change.from);
        toggle(&keys, change.placed, change.to);
        if (change.taken) |piece| toggle(&keys, piece, change.capture_square);
        if (change.rook) |rook| {
            const piece: p.Piece = .create(change.moving.color, .rook);
            toggle(&keys, piece, rook.from);
            toggle(&keys, piece, rook.to);
        }
        child.keys = keys;
        ev.advanceCachedInto(b, m, &self.acc, cache, &child.acc);
    }
};

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

    pub fn run(self: *Engine, board: *Position, net: ?*const Network, previous: []const u64, limits: Limits) Result {
        self.age +%= 1;
        self.killers = @splat(.{ .{}, .{} });
        var ctx = Context{ .engine = self, .net = net, .cache = .{ .network = net }, .limits = limits, .start = now(self.io) };
        const count = @min(previous.len, history_len);
        @memcpy(ctx.path[0..count], previous[previous.len - count ..]);
        ctx.root_at = count;
        ctx.path[count] = board.zobristKey();
        // The generator fills the threat cache lazily. Keep the caller's root state intact.
        var root = board.*;
        var root_state = board.state.*;
        root.state = &root_state;
        const root_node = Node.root(&root, &ctx.cache);
        const generated = allMoves(&root, &ctx.root_moves);
        const root_has_legal = generated.len != 0;
        ctx.root_count = generated.len;
        if (limits.root_moves) |allowed| {
            var kept: usize = 0;
            for (generated) |move| {
                if (std.mem.indexOfScalar(Move, allowed, move) != null) {
                    ctx.root_moves[kept] = move;
                    kept += 1;
                }
            }
            ctx.root_count = kept;
        }
        var result: Result = .{};
        if (ctx.root_count == 0) {
            result.score = if (root.checkers() != bitboard.empty and !root_has_legal) -mate else 0;
            return result;
        }
        result.best = ctx.root_moves[0];
        var depth: u8 = 1;
        var stable_iterations: u8 = 0;
        while (depth <= @min(limits.depth, max_ply - 2)) : (depth += 1) {
            ctx.root_best = result.best.?;
            var window: i32 = if (depth >= 5) 35 else infinity;
            var lo = @max(-infinity, result.score - window);
            var hi = @min(infinity, result.score + window);
            var score: i32 = 0;
            while (true) {
                score = ctx.search(&root, &root_node, depth, lo, hi, 0, true);
                if (ctx.aborted or (score > lo and score < hi)) break;
                window = @min(infinity, window * 3);
                if (score <= lo) lo = @max(-infinity, score - window);
                if (score >= hi) hi = @min(infinity, score + window);
            }
            if (ctx.aborted) break;
            stable_iterations = if (result.best == ctx.root_best) stable_iterations + 1 else 1;
            result.best = ctx.root_best;
            result.score = score;
            result.depth = depth;
            const elapsed = now(self.io) - ctx.start;
            var target_ms = limits.soft_ms;
            if (limits.adapt_game_clock and depth >= 8) {
                if (stable_iterations == 1) {
                    target_ms = @min(limits.hard_ms, target_ms +| @divTrunc(target_ms, 2));
                } else if (stable_iterations >= 4) {
                    target_ms -= @divTrunc(target_ms, 5);
                }
            }
            if (elapsed >= target_ms or score >= mate - @as(i32, depth)) break;
        }
        result.nodes = ctx.nodes;
        result.elapsed = now(self.io) - ctx.start;
        return result;
    }
};

const Context = struct {
    engine: *Engine,
    cache: ev.FrameCache,
    net: ?*const Network,
    limits: Limits,
    start: i64,
    nodes: u64 = 0,
    aborted: bool = false,
    path: [history_len + max_ply + 1]u64 = undefined,
    root_at: usize = 0,
    root_best: Move = .{},
    root_moves: [Move.max_moves]Move = undefined,
    root_count: usize = 0,

    fn visit(self: *Context) bool {
        self.nodes += 1;
        if (self.nodes >= self.limits.nodes or self.engine.stop.load(.monotonic) or
            ((self.nodes & 255) == 0 and now(self.engine.io) - self.start >= self.limits.hard_ms))
            self.aborted = true;
        return self.aborted;
    }

    fn drawn(self: *Context, b: *const Position, ply: usize) bool {
        if (insufficient(b)) return true;
        const idx = self.root_at + ply;
        const hash = b.zobristKey();
        self.path[idx] = hash;
        if (b.state.halfmove_clock >= 100) return true;
        const first = idx -| @as(usize, b.state.halfmove_clock);
        var n = idx;
        var previous_matches: u8 = 0;
        while (n >= first + 2) {
            n -= 2;
            if (self.path[n] != hash) continue;
            previous_matches += 1;
            if (n >= self.root_at or previous_matches == 2) return true;
        }
        return false;
    }

    fn scoreMove(self: *Context, b: *const Position, m: Move, tt: Move, ply: usize) i32 {
        if (m == tt) return 1000000;
        const captured = victim(b, m);
        if (captured != 0 or m.kind == .promotion) {
            const attacker = values[@backingInt(b.onSquare(m.source).?.type)];
            const bonus: i32 = if (m.kind == .promotion) values[@backingInt(m.promotionType())] else 0;
            const winning = bonus != 0 or attacker <= captured or exchange(b, m) >= 0;
            return (if (winning) @as(i32, 70000) else -25000) + 12 * captured - @divTrunc(attacker, 16) + bonus;
        }
        if (m == self.engine.killers[ply][0]) return 45000;
        if (m == self.engine.killers[ply][1]) return 44000;
        return self.engine.history[@backingInt(b.sideToMove())][@backingInt(m.source)][@backingInt(destination(m))];
    }

    fn order(self: *Context, b: *const Position, list: []const Move, tt: Move, ply: usize, scores: *[Move.max_moves]i32) void {
        for (list, scores[0..list.len]) |m, *score| score.* = self.scoreMove(b, m, tt, ply);
    }

    fn pick(list: []Move, scores: *[Move.max_moves]i32, i: usize) Move {
        var best = i;
        for (i + 1..list.len) |j| if (scores[j] > scores[best]) {
            best = j;
        };
        std.mem.swap(i32, &scores[i], &scores[best]);
        std.mem.swap(Move, &list[i], &list[best]);
        return list[i];
    }

    fn reward(self: *Context, side: p.Color, m: Move, bonus: i32) void {
        const hist = &self.engine.history[@backingInt(side)][@backingInt(m.source)][@backingInt(destination(m))];
        const value = @as(i32, hist.*) + bonus - @divTrunc(@as(i32, hist.*) * @as(i32, @intCast(@abs(bonus))), 16384);
        hist.* = @intCast(std.math.clamp(value, -16384, 16384));
    }

    fn adjusted(self: *Context, side: p.Color, keys: [3]u13, raw: i32) i32 {
        const entries = &self.engine.correction[@backingInt(side)];
        const total = 2 * @as(i32, entries[0][keys[0]]) + @as(i32, entries[1][keys[1]]) + entries[2][keys[2]];
        return raw + @divTrunc(total, 256);
    }

    fn learnCorrection(self: *Context, side: p.Color, keys: [3]u13, depth: i32, error_cp: i32) void {
        const target = std.math.clamp(error_cp, -200, 200) * 64;
        const weight = @min(16, depth + 1);
        inline for (0..3) |i| {
            const entry = &self.engine.correction[@backingInt(side)][i][keys[i]];
            entry.* = @intCast(@as(i32, entry.*) + @divTrunc((target - entry.*) * weight, 64));
        }
    }

    fn tableEntry(self: *Context, key: u64) *Entry {
        return &self.engine.table[@as(usize, @truncate(key)) & (self.engine.table.len - 1)];
    }

    fn cutoff(entry: Entry, b: *const Position, depth: i32, alpha: i32, beta: i32, ply: usize) ?i32 {
        if (entry.key != b.zobristKey() or entry.bound == .empty or entry.depth < depth) return null;
        if (@max(b.state.halfmove_clock, entry.halfmove) >= 80 and b.state.halfmove_clock != entry.halfmove) return null;
        const score = fromTable(entry.score, ply);
        if (entry.bound == .exact or (entry.bound == .lower and score >= beta) or
            (entry.bound == .upper and score <= alpha)) return score;
        return null;
    }

    fn saveQuietBound(self: *Context, slot: *Entry, b: *const Position, best_move: Move, score: i32, bound: Bound, ply: usize) void {
        if (slot.bound != .empty and slot.depth > 0 and (slot.key == b.zobristKey() or slot.age == self.engine.age)) return;
        slot.* = .{
            .key = b.zobristKey(),
            .move = best_move,
            .score = toTable(score, ply),
            .depth = 0,
            .bound = bound,
            .age = self.engine.age,
            .halfmove = @intCast(@min(b.state.halfmove_clock, 255)),
        };
    }

    fn quiescence(self: *Context, b: *Position, node: *const Node, alpha_in: i32, beta: i32, ply: usize) i32 {
        if (self.visit()) return 0;
        if (ply >= max_ply - 1) return ev.score(b, &node.acc, self.net);
        const checked = b.checkers() != bitboard.empty;
        if (self.drawn(b, ply)) {
            if (checked and !hasLegal(b)) return -mate + @as(i32, @intCast(ply));
            return 0;
        }
        const slot = self.tableEntry(b.zobristKey());
        const cached = slot.*;
        if (beta - alpha_in == 1) {
            if (cutoff(cached, b, 0, alpha_in, beta, ply)) |score| return score;
        }
        var alpha = alpha_in;
        var best_move: Move = .{};
        const stand = self.adjusted(b.sideToMove(), node.keys, ev.score(b, &node.acc, self.net));
        if (!checked) {
            if (stand >= beta) return if (hasLegal(b)) stand else 0;
            alpha = @max(alpha, stand);
        }
        var storage: [Move.max_moves]Move = undefined;
        const list = tacticalMoves(b, &storage);
        var scores: [Move.max_moves]i32 = undefined;
        self.order(b, list, if (cached.key == b.zobristKey()) cached.move else .{}, ply, &scores);
        for (0..list.len) |i| {
            const m = pick(list, &scores, i);
            const prune = !checked and m.kind != .promotion and
                (stand + victim(b, m) + 160 < alpha or exchange(b, m) < -75);
            const score = evaluate_move: {
                var state: Position.State = undefined;
                b.doMove(m, &state);
                defer b.undoMove(m);
                if (prune and b.checkers() == bitboard.empty) continue;
                @prefetch(self.tableEntry(b.zobristKey()), .{ .rw = .read, .locality = 3, .cache = .data });
                var child: Node = undefined;
                node.afterInto(b, m, &self.cache, &child);
                break :evaluate_move -self.quiescence(b, &child, -beta, -alpha, ply + 1);
            };
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
        if (list.len == 0) {
            if (checked) return -mate + @as(i32, @intCast(ply));
            if (!hasLegal(b)) return 0;
        }
        self.saveQuietBound(slot, b, best_move, alpha, if (alpha > alpha_in) .exact else .upper, ply);
        return alpha;
    }

    fn search(self: *Context, b: *Position, node: *const Node, depth_in: i32, alpha_in: i32, beta_in: i32, ply: usize, allow_null: bool) i32 {
        if (depth_in <= 0) return self.quiescence(b, node, alpha_in, beta_in, ply);
        if (self.visit()) return 0;
        if (ply >= max_ply - 1) return ev.score(b, &node.acc, self.net);
        const us = b.sideToMove();
        const checked = b.checkers() != bitboard.empty;
        if (ply > 0 and self.drawn(b, ply)) {
            if (checked and !hasLegal(b)) return -mate + @as(i32, @intCast(ply));
            return 0;
        }
        const distance: i32 = @intCast(ply);
        var alpha = @max(alpha_in, -mate + distance);
        const original = alpha;
        const beta = @min(beta_in, mate - distance - 1);
        if (alpha >= beta) return alpha;
        const depth = depth_in + @as(i32, @intFromBool(checked and ply < 32));
        const pv = beta - alpha > 1;
        const slot = self.tableEntry(b.zobristKey());
        const cached = slot.*;
        var tt_move: Move = .{};
        if (cached.bound != .empty and cached.key == b.zobristKey()) {
            tt_move = cached.move;
            if (ply > 0 and !pv) {
                if (cutoff(cached, b, depth, alpha, beta, ply)) |score| return score;
            }
        }
        if (ply == 0) tt_move = self.root_best;
        const raw = ev.score(b, &node.acc, self.net);
        const static = self.adjusted(us, node.keys, raw);
        if (ply > 0 and !pv and !checked and @abs(beta) < mate - max_ply) {
            if (depth <= 5 and static - 85 * depth >= beta and hasLegal(b)) return static;
            const nonpawn = b.colorOccupancy(us) & ~(b.typeOccupancy(.pawn) | b.typeOccupancy(.king));
            if (allow_null and depth >= 3 and static >= beta and nonpawn != 0) {
                var state: Position.State = undefined;
                b.doNullMove(&state);
                const score = -self.search(b, node, depth - 3 - @divTrunc(depth, 4), -beta, -beta + 1, ply + 1, false);
                b.undoNullMove();
                if (self.aborted) return 0;
                if (score >= beta and hasLegal(b)) return beta;
            }
        }
        var storage: [Move.max_moves]Move = undefined;
        const list = if (ply == 0) root: {
            const moves = storage[0..self.root_count];
            @memcpy(moves, self.root_moves[0..self.root_count]);
            break :root moves;
        } else allMoves(b, &storage);
        var scores: [Move.max_moves]i32 = undefined;
        self.order(b, list, tt_move, ply, &scores);
        var count: usize = 0;
        var best: i32 = -infinity;
        var best_move: Move = .{};
        var quiets: [Move.max_moves]Move = undefined;
        var quiet_count: usize = 0;
        for (0..list.len) |i| {
            const m = pick(list, &scores, i);
            count += 1;
            const quiet = victim(b, m) == 0 and m.kind != .promotion;
            const prune = count > 1 and !pv and !checked and best > -mate + max_ply and m.kind != .promotion and
                ((quiet and depth <= 3 and count > @as(usize, @intCast(3 + depth * depth)) and static + 90 * depth < alpha) or
                    (depth <= 4 and scores[i] < 0 and exchange(b, m) < -90 * depth));
            const score = evaluate_move: {
                var state: Position.State = undefined;
                b.doMove(m, &state);
                defer b.undoMove(m);
                const gives_check = b.checkers() != bitboard.empty;
                if (prune and !gives_check) continue;
                @prefetch(self.tableEntry(b.zobristKey()), .{ .rw = .read, .locality = 3, .cache = .data });
                var child: Node = undefined;
                node.afterInto(b, m, &self.cache, &child);
                const remaining = depth - 1;
                if (count == 1)
                    break :evaluate_move -self.search(b, &child, remaining, -beta, -alpha, ply + 1, true);
                var reduction: i32 = 0;
                if (depth >= 3 and count >= 4 and quiet and !checked and !gives_check and scores[i] < 44000) {
                    reduction = reductions[@intCast(@min(depth, 63))][@min(count, 63)];
                    if (!pv) reduction += 1;
                    reduction -= @divTrunc(@as(i32, self.engine.history[@backingInt(us)][@backingInt(m.source)][@backingInt(destination(m))]), 6000);
                    reduction = std.math.clamp(reduction, 0, remaining - 1);
                }
                var value = -self.search(b, &child, remaining - reduction, -alpha - 1, -alpha, ply + 1, true);
                if (value > alpha and reduction > 0) value = -self.search(b, &child, remaining, -alpha - 1, -alpha, ply + 1, true);
                if (pv and value > alpha and value < beta) value = -self.search(b, &child, remaining, -beta, -alpha, ply + 1, true);
                break :evaluate_move value;
            };
            if (self.aborted) return 0;
            if (score > best) {
                best = score;
                best_move = m;
                if (ply == 0) self.root_best = m;
            }
            alpha = @max(alpha, score);
            if (alpha >= beta) {
                if (quiet) {
                    if (m != self.engine.killers[ply][0]) {
                        self.engine.killers[ply][1] = self.engine.killers[ply][0];
                        self.engine.killers[ply][0] = m;
                    }
                    const bonus = @min(1200, 30 * depth * depth);
                    self.reward(us, m, bonus);
                    for (quiets[0..quiet_count]) |q| self.reward(us, q, -@divTrunc(3 * bonus, 4));
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
        if (!checked and victim(b, best_move) == 0 and best_move.kind != .promotion and @abs(best) < mate - max_ply and
            (best < beta or best > static) and (best > original or best < static))
        {
            self.learnCorrection(us, node.keys, depth, best - raw);
        }
        if (slot.key == b.zobristKey() or slot.age != self.engine.age or slot.depth <= depth + 2) {
            slot.* = .{
                .key = b.zobristKey(),
                .move = best_move,
                .score = toTable(best, ply),
                .depth = @intCast(@min(depth, 120)),
                .bound = if (best >= beta) .lower else if (best <= original) .upper else .exact,
                .age = self.engine.age,
                .halfmove = @intCast(@min(b.state.halfmove_clock, 255)),
            };
        }
        return best;
    }
};
