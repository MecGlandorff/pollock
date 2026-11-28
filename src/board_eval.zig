//! Incremental search evaluation on Pollock's native position.
const std = @import("std");
const p = @import("pollock");
const king = @import("king_nnue.zig");
const wide = @import("wide_nnue.zig");
const Position = p.Position;
const Move = p.Move;
const Piece = p.Piece;
const Square = p.Square;

pub const Acc = struct {
    wide: wide.Acc,
    /// White's signed material balance with a network, classical piece-square sum otherwise.
    balance: i32,
};

pub const Change = struct {
    from: Square,
    to: Square,
    moving: Piece,
    placed: Piece,
    taken: ?Piece,
    capture_square: Square,
    rook: ?struct { from: Square, to: Square },

    /// Decode the physical piece changes immediately after Position.doMove.
    pub inline fn after(pos: *const Position, move: Move) Change {
        const us = pos.sideToMove().opposite();
        if (move.kind == .castle) {
            const short = move.source.less(move.destination);
            const k = Piece.create(us, .king);
            return .{
                .from = move.source,
                .to = .relative(if (short) .g1 else .c1, us),
                .moving = k,
                .placed = k,
                .taken = null,
                .capture_square = move.destination,
                .rook = .{ .from = move.destination, .to = .relative(if (short) .f1 else .d1, us) },
            };
        }
        const placed = pos.onSquare(move.destination).?;
        return .{
            .from = move.source,
            .to = move.destination,
            .moving = if (move.kind == .promotion) .create(us, .pawn) else placed,
            .placed = placed,
            .taken = pos.state.captured_piece,
            .capture_square = if (move.kind == .en_passant) .fromCoords(move.destination.file(), move.source.rank()) else move.destination,
            .rook = null,
        };
    }
};

/// Wide128's loader bounds its i16 accumulators for up to 32 active features.
pub fn validate(pos: *const Position) !void {
    if (@popCount(pos.totalOccupancy()) > 32) return error.InvalidPieceCount;
    for (std.enums.values(p.Color)) |side| {
        if (@popCount(pos.pieceOccupancy(side, .king)) != 1) return error.InvalidKings;
    }
}

inline fn code(piece: Piece) u8 {
    return 1 + 6 * @as(u8, @backingInt(piece.color)) + @as(u8, @backingInt(piece.type));
}

pub fn squareCodes(pos: *const Position) [64]u8 {
    var squares: [64]u8 = undefined;
    for (pos.board.values, &squares) |piece, *sq| sq.* = if (piece) |pc| code(pc) else 0;
    return squares;
}

inline fn material(piece: Piece) i32 {
    const value = king.material[@backingInt(piece.type)];
    return if (piece.color == .white) value else -value;
}

fn classical(piece: Piece, sq: Square) i32 {
    const rel = sq.relative(piece.color);
    const r: i32 = @backingInt(rel.rank());
    const f: i32 = @backingInt(rel.file());
    const center = 14 - @as(i32, @intCast(@abs(2 * r - 7) + @abs(2 * f - 7)));
    const value: i32 = switch (piece.type) {
        .pawn => 100 + 2 * r * r + center,
        .knight => 300 + 4 * center,
        .bishop => 322 + 2 * center,
        .rook => 500 + 2 * r + (if (r == 6) @as(i32, 14) else 0),
        .queen => 920 + center,
        .king => 0,
    };
    return if (piece.color == .white) value else -value;
}

/// One search owns its cache and its immutable evaluation network for the entire run.
pub const FrameCache = struct {
    network: ?*const wide.Network,
    valid: [2]u16 = .{ 0, 0 },
    entries: [2][16]Entry = undefined,

    const Column = [wide.width]i16;
    const Entry = struct {
        values: Column align(32),
        pieces: [12]u64,
    };

    fn occupancies(pos: *const Position) [12]u64 {
        var bits: [12]u64 = undefined;
        inline for (0..2) |color| {
            inline for (0..6) |kind| {
                bits[color * 6 + kind] = pos.color_occupancy.values[color] & pos.type_occupancy.values[kind];
            }
        }
        return bits;
    }

    fn changedColumns(net: *const wide.Network, frame: king.Frame, side: u1, old: *const [12]u64, new: *const [12]u64,
        remove: *[32]*const Column, add: *[32]*const Column) [2]usize {
        var removed: usize = 0;
        var added: usize = 0;
        for (old, new, 0..) |a, b, index| {
            const pc: u8 = @intCast(index + 1);
            var subtract = a & ~b;
            while (subtract != 0) : (subtract &= subtract - 1) {
                const sq: u6 = @intCast(@ctz(subtract));
                remove[removed] = &net.feature_weights[frame.bucket][king.Network.input(pc, sq, side, frame.mask)];
                removed += 1;
            }
            var insert = b & ~a;
            while (insert != 0) : (insert &= insert - 1) {
                const sq: u6 = @intCast(@ctz(insert));
                add[added] = &net.feature_weights[frame.bucket][king.Network.input(pc, sq, side, frame.mask)];
                added += 1;
            }
        }
        return .{ removed, added };
    }

    fn update(old: *Column, dest: *Column, removed: []const *const Column, added: []const *const Column) void {
        if (removed.len == 0 and added.len == 0) {
            dest.* = old.*;
            return;
        }
        const width = 128;
        const Block = @Vector(width, i16);
        for (0..wide.width / width) |block| {
            const start = block * width;
            var sum: Block = old[start..][0..width].*;
            for (removed) |column| sum -= @as(Block, column[start..][0..width].*);
            for (added) |column| sum += @as(Block, column[start..][0..width].*);
            old[start..][0..width].* = sum;
            dest[start..][0..width].* = sum;
        }
    }

    fn refreshSide(self: *FrameCache, pos: *const Position, dest: *wide.Acc, side: u1, king_square: u6) void {
        const net = self.network.?;
        const frame = king.Frame.init(king_square, side);
        const slot: u4 = (@as(u4, frame.bucket) << 1) | @intFromBool((frame.mask & 7) != 0);
        const flag: u16 = @as(u16, 1) << slot;
        const entry = &self.entries[side][slot];
        const pieces = occupancies(pos);
        if ((self.valid[side] & flag) == 0) {
            const squares = squareCodes(pos);
            net.refresh(dest, side, king_square, &squares);
            entry.values = dest.values[side];
            self.valid[side] |= flag;
        } else {
            var removed: [32]*const Column = undefined;
            var added: [32]*const Column = undefined;
            const count = changedColumns(net, frame, side, &entry.pieces, &pieces, &removed, &added);
            update(&entry.values, &dest.values[side], removed[0..count[0]], added[0..count[1]]);
            dest.frames[side] = frame;
        }
        entry.pieces = pieces;
    }
};


pub fn refresh(pos: *const Position, net: ?*const wide.Network) Acc {
    return refreshImpl(pos, net, null);
}
pub fn refreshCached(pos: *const Position, cache: *FrameCache) Acc {
    return refreshImpl(pos, cache.network, cache);
}
inline fn refreshImpl(pos: *const Position, net: ?*const wide.Network, cache: ?*FrameCache) Acc {
    var result: Acc = .{ .wide = .{}, .balance = 0 };
    for (pos.board.values, 0..) |piece, index| {
        if (piece) |pc| result.balance += if (net != null) material(pc) else classical(pc, @fromBackingInt(@as(u6, @intCast(index))));
    }
    if (net) |n| {
        if (cache) |table| {
            inline for (std.enums.values(p.Color)) |side| {
                table.refreshSide(pos, &result.wide, @backingInt(side), @backingInt(pos.kingSquare(side)));
            }
        } else {
            const squares = squareCodes(pos);
            inline for (std.enums.values(p.Color)) |side| {
                n.refresh(&result.wide, @backingInt(side), @backingInt(pos.kingSquare(side)), &squares);
            }
        }
    }
    return result;
}

pub fn advance(pos: *const Position, move: Move, parent: *const Acc, net: ?*const wide.Network) Acc {
    var result: Acc = undefined;
    advanceImpl(pos, move, parent, net, null, &result);
    return result;
}
pub fn advanceCached(pos: *const Position, move: Move, parent: *const Acc, cache: *FrameCache) Acc {
    var result: Acc = undefined;
    advanceCachedInto(pos, move, parent, cache, &result);
    return result;
}
/// Write directly into the child's accumulator. The parent remains live during the update.
pub fn advanceCachedInto(pos: *const Position, move: Move, parent: *const Acc, cache: *FrameCache, result: *Acc) void {
    advanceImpl(pos, move, parent, cache.network, cache, result);
}
inline fn advanceImpl(pos: *const Position, move: Move, parent: *const Acc, net: ?*const wide.Network, cache: ?*FrameCache, result: *Acc) void {
    const ch = Change.after(pos, move);
    result.balance = parent.balance;
    if (net) |n| {
        if (ch.taken) |taken| result.balance -= material(taken);
        if (move.kind == .promotion) result.balance += material(ch.placed) - material(ch.moving);
        const delta: wide.Network.Change = .{
            .from = @backingInt(ch.from),
            .to = @backingInt(ch.to),
            .moving = code(ch.moving),
            .placed = code(ch.placed),
            .taken = if (ch.taken) |pc| code(pc) else 0,
            .capture_square = @backingInt(ch.capture_square),
            .king_move = ch.moving.type == .king,
            .castle = ch.rook != null,
        };
        const rook: ?wide.Network.RookChange = if (ch.rook) |r| .{
            .from = @backingInt(r.from),
            .to = @backingInt(r.to),
            .piece = code(.create(ch.moving.color, .rook)),
        } else null;
        inline for (0..2) |side| {
            if (delta.king_move and side == @backingInt(ch.moving.color) and !std.meta.eql(parent.wide.frames[side], king.Frame.init(delta.to, side))) {
                if (cache) |table| {
                    table.refreshSide(pos, &result.wide, side, delta.to);
                } else {
                    const squares = squareCodes(pos);
                    n.refresh(&result.wide, side, delta.to, &squares);
                }
            } else {
                n.advanceInFrame(&parent.wide, &result.wide, side, delta, rook);
            }
        }
    } else {
        result.wide = .{};
        result.balance += classical(ch.placed, ch.to) - classical(ch.moving, ch.from);
        if (ch.taken) |taken| result.balance -= classical(taken, ch.capture_square);
        if (ch.rook) |r| {
            const rook = Piece.create(ch.moving.color, .rook);
            result.balance += classical(rook, r.to) - classical(rook, r.from);
        }
    }
}

pub fn score(pos: *const Position, acc: *const Acc, net: ?*const wide.Network) i32 {
    if (net) |n| {
        const raw = n.score(&acc.wide, acc.balance, @popCount(pos.totalOccupancy()), @backingInt(pos.sideToMove()));
        return std.math.clamp(raw, -20000, 20000);
    }
    return (if (pos.sideToMove() == .white) acc.balance else -acc.balance) + 9;
}
