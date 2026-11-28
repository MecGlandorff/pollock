const std = @import("std");
const Io = std.Io;

const pollock = @import("pollock");
const Position = pollock.Position;

fn readFen(position: *Position, state: *Position.State, fen: []const u8) !void {
    const rest = try pollock.uci_position.readFen(position, state, fen);
    if (rest.len != 0) return error.UnexpectedFenSuffix;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (args.len == 1 or std.mem.eql(u8, args[1], "uci") or std.mem.eql(u8, args[1], "--weights")) {
        const first: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "uci")) 2 else 1;
        var net: ?*pollock.wide_nnue.Network = null;
        if (args.len > first) {
            if (args.len != first + 2 or !std.mem.eql(u8, args[first], "--weights")) return error.ExpectedWeightsPath;
            net = try pollock.uci.loadWeights(init.io, std.heap.page_allocator, args[first + 1]);
        }
        return pollock.uci.loop(init.io, stdout, net);
    }
    var position: Position = undefined;
    var state: Position.State = undefined;

    if (std.mem.eql(u8, args[1], "perft")) {
        if (args.len < 3 or args.len > 4) return error.ExpectedDepthAndOptionalFen;

        const depth = try std.fmt.parseUnsigned(u8, args[2], 10);
        if (args.len == 4)
            try readFen(&position, &state, args[3])
        else
            position.setStartPosition(&state);

        try stdout.print("{d}\n", .{pollock.perft.perft(&position, depth)});
    } else if (std.mem.eql(u8, args[1], "eval")) {
        const explicit = args.len > 2 and std.mem.eql(u8, args[2], "--weights");
        const first_fen: usize = if (explicit) 4 else 2;
        if (args.len <= first_fen) return error.ExpectedFen;
        const path = if (explicit) args[3] else "runs/v0/network.json";
        const bytes = try Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(16 * 1024 * 1024));
        var net = try pollock.nnue.Network.load(arena, bytes);
        defer net.deinit(arena);
        for (args[first_fen..]) |fen| {
            try readFen(&position, &state, fen);
            const layer = try net.refreshChecked(&position);
            try stdout.print("{d}\n", .{net.score(&layer, position.sideToMove())});
        }
    } else {
        position.setStartPosition(&state);
        try stdout.print("{f}\n", .{position});
    }

    try stdout.flush();
}
