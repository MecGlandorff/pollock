const std = @import("std");
const Io = std.Io;

const pollock = @import("pollock");
const Position = pollock.Position;

fn readFen(position: *Position, info: *Position.Info, fen: []const u8) !void {
    const rest = try position.setFen(info, fen, null);
    if (rest.len != 0) return error.UnexpectedFenSuffix;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var position: Position = undefined;
    var info: Position.Info = undefined;
    if (args.len == 1 or std.mem.eql(u8, args[1], "uci") or std.mem.eql(u8, args[1], "--weights")) {
        const uci = @import("uci.zig");
        const start: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "uci")) 2 else 1;
        var net: ?pollock.nnue.Network = null;
        if (args.len > start) {
            if (args.len != start + 2 or !std.mem.eql(u8, args[start], "--weights")) return error.ExpectedWeightsPath;
            net = try uci.loadWeights(io, std.heap.page_allocator, args[start + 1]);
        }
        return uci.loop(io, stdout_writer, net);
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "perft")) {
        if (args.len < 3 or args.len > 4) return error.ExpectedDepthAndOptionalFen;
        const depth = try std.fmt.parseUnsigned(u8, args[2], 10);
        if (args.len == 4) try readFen(&position, &info, args[3]) else position.setStartPosition(&info);
        const board = try pollock.movegen.Board.fromPosition(&position, null);
        try stdout_writer.print("{d}\n", .{pollock.movegen.perft(&board, depth)});
        return stdout_writer.flush();
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "eval")) {
        const explicit_weights = args.len > 2 and std.mem.eql(u8, args[2], "--weights");
        const first_fen: usize = if (explicit_weights) 4 else 2;
        if (args.len <= first_fen) return error.ExpectedFen;
        const path = if (explicit_weights) args[3] else "runs/v0/network.json";
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024));
        const net = try pollock.nnue.Network.load(arena, bytes);
        try readFen(&position, &info, args[first_fen]);
        const base = try net.refreshChecked(&position);
        try stdout_writer.print("{d}\n", .{net.score(&base, position.side_to_move)});
        for (args[first_fen + 1 ..]) |fen| {
            var child: Position = undefined;
            var child_info: Position.Info = undefined;
            try readFen(&child, &child_info, fen);
            var layer = base;
            try net.updateChecked(&layer, &position, &child);
            try stdout_writer.print("{d}\n", .{net.score(&layer, child.side_to_move)});
        }
    } else {
        for (args) |arg| std.log.info("arg: {s}", .{arg});
        position.setStartPosition(&info);
        try stdout_writer.print("{f}\n", .{position});
    }

    try stdout_writer.flush();
}
