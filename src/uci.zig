//! Standard-chess UCI session. Search runs on a worker so stop and isready stay responsive.
const std = @import("std");
const p = @import("pollock");
const mg = p.movegen;
const search = p.search;
const Network = p.nnue.Network;
const Io = std.Io;

const Output = struct {
    writer: *Io.Writer,
    io: Io,
    mutex: Io.Mutex = .init,

    fn send(self: *Output, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writer.print(fmt, args) catch return;
        self.writer.flush() catch return;
    }
};

pub fn loadWeights(io: Io, allocator: std.mem.Allocator, path: []const u8) !Network {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    return Network.load(allocator, bytes);
}

const GoOption = enum { searchmoves, infinite, ponder, mate, depth, nodes, movetime, movestogo, wtime, btime, winc, binc };

const Session = struct {
    io: Io,
    allocator: std.mem.Allocator,
    output: Output,
    engine: search.Engine,
    network: ?Network,
    board: mg.Board = .{},
    past: [128]u64 = undefined,
    past_count: usize = 0,
    last_position: [64 * 1024]u8 = undefined,
    last_length: usize = 0,
    last_has_moves: bool = false,
    move_overhead_ms: i64 = 35,
    worker: ?std.Thread = null,
    root_moves: mg.List = .{},
    // Written by an infinite-search worker and consumed only after joining it.
    pending_result: ?search.Result = null,

    fn net(self: *Session) ?*const Network {
        if (self.network) |*n| return n;
        return null;
    }

    fn stop(self: *Session) void {
        if (self.worker) |thread| {
            self.engine.stop.store(true, .release);
            thread.join();
            self.worker = null;
            if (self.pending_result) |result| {
                self.sendBestmove(result);
                self.pending_result = null;
            }
        }
    }

    fn position(self: *Session, text: []const u8, remember: bool) !void {
        if (text.len > self.last_position.len) return error.PositionTooLong;
        const cached = self.last_position[0..self.last_length];
        if (remember and std.mem.eql(u8, text, cached) and cached.len != 0) return;
        const extends_cached = remember and cached.len > 0 and text.len > cached.len and
            std.mem.startsWith(u8, text, cached) and std.ascii.isWhitespace(text[cached.len]);
        var current: mg.Board = undefined;
        var past: [128]u64 = undefined;
        var count: usize = 0;
        var has_moves = false;
        var rest: []const u8 = undefined;
        if (extends_cached) {
            current = self.board;
            count = self.past_count;
            @memcpy(past[0..count], self.past[0..count]);
            rest = std.mem.trim(u8, text[cached.len..], " \t");
            has_moves = self.last_has_moves;
        } else {
            var original: p.Position = undefined;
            var state: p.Position.State = undefined;
            if (std.mem.eql(u8, text, "startpos") or std.mem.startsWith(u8, text, "startpos ")) {
                original.setStartPosition(&state);
                rest = std.mem.trim(u8, text["startpos".len..], " \t");
            } else if (std.mem.startsWith(u8, text, "fen ")) {
                rest = try original.setFen(&state, text[4..], false);
                rest = std.mem.trim(u8, rest, " \t");
            } else return error.InvalidPosition;
            current = try mg.Board.fromPosition(&original, self.net());
        }
        if (rest.len != 0) {
            var tok = std.mem.tokenizeAny(u8, rest, " \t");
            if (!has_moves and !std.mem.eql(u8, tok.next() orelse return error.ExpectedMoves, "moves")) return error.ExpectedMoves;
            has_moves = true;
            while (tok.next()) |notation| {
                const next = mg.playUci(&current, notation, self.net()) orelse return error.IllegalMove;
                if (next.halfmove == 0) count = 0 else {
                    if (count == past.len) {
                        @memmove(past[0 .. past.len - 1], past[1..]);
                        count -= 1;
                    }
                    past[count] = current.hash;
                    count += 1;
                }
                current = next;
            }
        }
        self.board = current;
        @memcpy(self.past[0..count], past[0..count]);
        self.past_count = count;
        if (remember) {
            @memcpy(self.last_position[0..text.len], text);
            self.last_length = text.len;
            self.last_has_moves = has_moves;
        }
    }

    fn bestmoveName(result: search.Result, buf: *[5]u8) []const u8 {
        return if (result.best) |move| mg.uciName(move, buf) else "0000";
    }

    fn sendBestmove(self: *Session, result: search.Result) void {
        var buf: [5]u8 = undefined;
        self.output.send("bestmove {s}\n", .{bestmoveName(result, &buf)});
    }

    fn run(self: *Session, limits: search.Limits, infinite: bool) void {
        const r = self.engine.run(self.board, self.net(), self.past[0..self.past_count], limits);
        var buf: [5]u8 = undefined;
        const move = bestmoveName(r, &buf);
        const nps = r.nodes * 1000 / @as(u64, @intCast(@max(1, r.elapsed)));
        if (@abs(r.score) > search.mate - 96) {
            const plies = search.mate - @as(i32, @intCast(@abs(r.score)));
            const full = @divTrunc(plies + 1, 2) * (if (r.score < 0) @as(i32, -1) else 1);
            self.output.send("info depth {d} score mate {d} nodes {d} time {d} nps {d} pv {s}\n", .{ r.depth, full, r.nodes, r.elapsed, nps, move });
        } else self.output.send("info depth {d} score cp {d} nodes {d} time {d} nps {d} pv {s}\n", .{ r.depth, r.score, r.nodes, r.elapsed, nps, move });
        if (infinite) {
            self.pending_result = r;
        } else {
            self.sendBestmove(r);
        }
    }

    fn go(self: *Session, text: []const u8) !void {
        self.stop();
        var limits: search.Limits = .{};
        var infinite = false;
        self.root_moves.len = 0;
        var remaining: [2]i64 = .{ -1, -1 };
        var inc: [2]i64 = .{ 0, 0 };
        var movetime: i64 = -1;
        var mtg: i64 = 26;
        var tok = std.mem.tokenizeAny(u8, text, " \t");
        while (tok.next()) |token| {
            const option = std.meta.stringToEnum(GoOption, token) orelse return error.UnsupportedGoOption;
            switch (option) {
                .infinite => {
                    infinite = true;
                    continue;
                },
                .searchmoves => {
                    var generated: mg.List = .{};
                    self.board.generate(false, &generated);
                    while (tok.peek()) |name| {
                        if (std.meta.stringToEnum(GoOption, name) != null) break;
                        _ = tok.next();
                        const move = generated.findUci(name) orelse continue;
                        if (!self.root_moves.contains(move)) {
                            self.root_moves.moves[self.root_moves.len] = move;
                            self.root_moves.len += 1;
                        }
                    }
                    limits.root_moves = &self.root_moves;
                    continue;
                },
                .ponder, .mate => return error.UnsupportedGoOption,
                else => {},
            }
            const value = std.fmt.parseInt(i64, tok.next() orelse return error.ExpectedNumber, 10) catch return error.ExpectedNumber;
            const v = std.math.clamp(value, 0, 864000000);
            switch (option) {
                .depth => limits.depth = @intCast(std.math.clamp(v, 1, 94)),
                .nodes => limits.nodes = @intCast(@max(value, 1)),
                .movetime => movetime = v,
                .movestogo => mtg = std.math.clamp(v, 1, 100),
                .wtime => remaining[0] = v,
                .btime => remaining[1] = v,
                .winc => inc[0] = v,
                .binc => inc[1] = v,
                else => unreachable,
            }
        }
        if (movetime >= 0) {
            limits.hard_ms = @max(1, movetime - @min(10, @divTrunc(movetime, 12)));
            limits.soft_ms = limits.hard_ms;
        } else if (remaining[self.board.side] >= 0) {
            const t = remaining[self.board.side];
            const reserve = @max(self.move_overhead_ms, @min(75, @divTrunc(t, 12)));
            const available = @max(1, t - reserve);
            const ideal = @divTrunc(available, mtg) + @divTrunc(3 * inc[self.board.side], 4);
            limits.soft_ms = std.math.clamp(ideal, 1, @max(1, @divTrunc(available, 2)));
            limits.hard_ms = @min(available, @max(limits.soft_ms + 2, limits.soft_ms * 3));
        }
        self.engine.stop.store(false, .release);
        self.worker = try std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, run, .{ self, limits, infinite });
    }

    fn setOption(self: *Session, text: []const u8) !void {
        const separator = std.mem.indexOf(u8, text, " value ") orelse return error.InvalidOption;
        const name = std.mem.trim(u8, text[0..separator], " ");
        const value = std.mem.trim(u8, text[separator + 7 ..], " ");
        self.stop();
        if (std.ascii.eqlIgnoreCase(name, "Hash")) {
            const size = try std.fmt.parseUnsigned(usize, value, 10);
            if (size < 1 or size > 256) return error.HashOutOfRange;
            const table = try createTable(self.allocator, size);
            self.allocator.free(self.engine.table);
            self.engine.table = table;
        } else if (std.ascii.eqlIgnoreCase(name, "Move Overhead")) {
            const overhead = try std.fmt.parseUnsigned(u16, value, 10);
            if (overhead > 1000) return error.MoveOverheadOutOfRange;
            self.move_overhead_ms = overhead;
        } else if (std.ascii.eqlIgnoreCase(name, "EvalFile")) {
            const next = if (std.mem.eql(u8, value, "<empty>")) null else try loadWeights(self.io, self.allocator, value);
            if (self.network) |*old| old.deinit(self.allocator);
            self.network = next;
            try self.position(self.last_position[0..self.last_length], false);
            self.engine.reset();
        } else return error.UnknownOption;
    }

    fn command(self: *Session, line: []const u8) !bool {
        if (std.mem.eql(u8, line, "uci")) {
            self.output.send("id name Pollock Zig\nid author Pollock\noption name Hash type spin default 16 min 1 max 256\noption name EvalFile type string default <empty>\noption name Move Overhead type spin default 35 min 0 max 1000\nuciok\n", .{});
        } else if (std.mem.eql(u8, line, "isready")) {
            self.output.send("readyok\n", .{});
        } else if (std.mem.eql(u8, line, "ucinewgame")) {
            self.stop();
            self.engine.reset();
            try self.position("startpos", true);
        } else if (std.mem.startsWith(u8, line, "position ")) {
            self.stop();
            try self.position(line[9..], true);
        } else if (std.mem.eql(u8, line, "go") or std.mem.startsWith(u8, line, "go ")) {
            try self.go(line[2..]);
        } else if (std.mem.eql(u8, line, "stop")) {
            self.stop();
        } else if (std.mem.startsWith(u8, line, "setoption name ")) {
            try self.setOption(line[15..]);
        } else if (std.mem.eql(u8, line, "quit")) return false;
        return true;
    }
};

fn createTable(allocator: std.mem.Allocator, mb: usize) ![]search.Entry {
    const max_count = mb * 1024 * 1024 / @sizeOf(search.Entry);
    var size: usize = 1;
    while (size <= max_count / 2) size *= 2;
    const entries = try allocator.alloc(search.Entry, size);
    @memset(entries, .{});
    return entries;
}

pub fn loop(io: Io, writer: *Io.Writer, initial_net: ?Network) !void {
    const allocator = std.heap.page_allocator;
    var owned_net = initial_net;
    const table = createTable(allocator, 16) catch |err| {
        if (owned_net) |*net| net.deinit(allocator);
        return err;
    };
    var session = Session{
        .io = io,
        .allocator = allocator,
        .output = .{ .io = io, .writer = writer },
        .engine = .{ .io = io, .table = table },
        .network = owned_net,
    };
    defer allocator.free(session.engine.table);
    defer if (session.network) |*net| net.deinit(allocator);
    defer session.stop();
    try session.position("startpos", true);
    var input_buf: [128 * 1024]u8 = undefined;
    var input = Io.File.stdin().reader(io, &input_buf);
    while (try input.interface.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        const again = session.command(line) catch |err| {
            session.output.send("info string {s}\n", .{@errorName(err)});
            continue;
        };
        if (!again) break;
    }
}
