//! Standard-chess UCI session. Search runs on a worker so stop and isready stay responsive.
const std = @import("std");
const p = @import("pollock");
const game_io = p.uci_position;
const search = p.search;
const Network = p.wide_nnue.Network;
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

pub fn loadWeights(io: Io, allocator: std.mem.Allocator, path: []const u8) !*Network {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return Network.load(allocator, bytes);
}

const GoOption = enum { searchmoves, infinite, ponder, mate, depth, nodes, movetime, movestogo, wtime, btime, winc, binc };

const Session = struct {
    io: Io,
    allocator: std.mem.Allocator,
    output: Output,
    engine: search.Engine,
    network: ?*Network,
    game: game_io.Game,
    last_position: [64 * 1024]u8 = undefined,
    last_length: usize = 0,
    move_overhead_ms: i64 = 35,
    worker: ?std.Thread = null,
    root_moves: [p.Move.max_moves]p.Move = undefined,
    // Written by an infinite-search worker and consumed only after joining it.
    pending_result: ?search.Result = null,

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

    fn position(self: *Session, text: []const u8) !void {
        if (text.len > self.last_position.len) return error.PositionTooLong;
        const cached = self.last_position[0..self.last_length];
        if (cached.len != 0 and std.mem.eql(u8, text, cached)) return;
        if (cached.len != 0 and text.len > cached.len and std.mem.startsWith(u8, text, cached) and std.ascii.isWhitespace(text[cached.len])) {
            try self.game.extend(text[cached.len..]);
        } else {
            var next = game_io.Game.init(self.allocator);
            errdefer next.deinit();
            try next.parse(text);
            self.game.deinit();
            self.game = next;
        }
        @memcpy(self.last_position[0..text.len], text);
        self.last_length = text.len;
    }

    fn bestmoveName(result: search.Result, buf: *[5]u8) []const u8 {
        return if (result.best) |move| game_io.name(move, buf) else "0000";
    }

    fn sendBestmove(self: *Session, result: search.Result) void {
        var buf: [5]u8 = undefined;
        self.output.send("bestmove {s}\n", .{bestmoveName(result, &buf)});
    }

    fn run(self: *Session, limits: search.Limits, infinite: bool) void {
        var past: [128]u64 = undefined;
        const previous = self.game.previousKeys(&past);
        const r = self.engine.run(&self.game.board, self.network, previous, limits);
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
        var root_count: usize = 0;
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
                    var buffer: [p.Move.max_moves]p.Move = undefined;
                    var generated: p.movegen.MoveList = .initBuffer(&buffer);
                    p.movegen.generateLegalMoves(&self.game.board, &generated, .all);
                    while (tok.peek()) |name| {
                        if (std.meta.stringToEnum(GoOption, name) != null) break;
                        _ = tok.next();
                        const move = game_io.findMove(generated.items, name) orelse continue;
                        if (std.mem.indexOfScalar(p.Move, self.root_moves[0..root_count], move) == null) {
                            self.root_moves[root_count] = move;
                            root_count += 1;
                        }
                    }
                    limits.root_moves = self.root_moves[0..root_count];
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
        const side = @backingInt(self.game.board.sideToMove());
        if (movetime >= 0) {
            limits.hard_ms = @max(1, movetime - @min(10, @divTrunc(movetime, 12)));
            limits.soft_ms = limits.hard_ms;
        } else if (remaining[side] >= 0) {
            limits.adapt_game_clock = limits.root_moves == null;
            const t = remaining[side];
            const reserve = @max(self.move_overhead_ms, @min(75, @divTrunc(t, 12)));
            const available = @max(1, t - reserve);
            const ideal = @divTrunc(available, mtg) + @divTrunc(3 * inc[side], 4);
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
            if (self.network) |old_net| self.allocator.destroy(old_net);
            self.network = next;
            self.engine.reset();
        } else return error.UnknownOption;
    }

    fn command(self: *Session, line: []const u8) !bool {
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        const verb = tokens.next() orelse return true;
        if (std.mem.eql(u8, verb, "uci")) {
            self.output.send("id name Pollock mec_3400\nid author Pollock\noption name Hash type spin default 16 min 1 max 256\noption name EvalFile type string default <empty>\noption name Move Overhead type spin default 35 min 0 max 1000\nuciok\n", .{});
        } else if (std.mem.eql(u8, verb, "isready")) {
            self.output.send("readyok\n", .{});
        } else if (std.mem.eql(u8, verb, "ucinewgame")) {
            self.stop();
            self.engine.reset();
            try self.position("startpos");
        } else if (std.mem.eql(u8, verb, "position")) {
            self.stop();
            try self.position(tokens.rest());
        } else if (std.mem.eql(u8, verb, "go")) {
            try self.go(tokens.rest());
        } else if (std.mem.eql(u8, verb, "stop")) {
            self.stop();
        } else if (std.mem.eql(u8, verb, "setoption")) {
            if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidOption, "name")) return error.InvalidOption;
            try self.setOption(tokens.rest());
        } else if (std.mem.eql(u8, verb, "quit")) return false;
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

pub fn loop(io: Io, writer: *Io.Writer, initial_net: ?*Network) !void {
    const allocator = std.heap.page_allocator;
    const table = createTable(allocator, 16) catch |err| {
        if (initial_net) |net| allocator.destroy(net);
        return err;
    };
    var session = Session{
        .io = io,
        .allocator = allocator,
        .output = .{ .io = io, .writer = writer },
        .engine = .{ .io = io, .table = table },
        .network = initial_net,
        .game = game_io.Game.init(allocator),
    };
    defer allocator.free(session.engine.table);
    defer if (session.network) |net| allocator.destroy(net);
    defer session.game.deinit();
    defer session.stop();
    try session.position("startpos");
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
