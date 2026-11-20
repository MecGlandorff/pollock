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
    if (args.len >= 2 and std.mem.eql(u8, args[1], "eval")) {
        const explicit_weights = args.len > 2 and std.mem.eql(u8, args[2], "--weights");
        const first_fen: usize = if (explicit_weights) 4 else 2;
        if (args.len <= first_fen) return error.ExpectedFen;
        const path = if (explicit_weights) args[3] else "runs/v0/network.json";
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024));
        const net = try pollock.nnue.Network.load(arena, bytes);
        try readFen(&position, &info, args[first_fen]);
        const base = net.refresh(&position);
        try stdout_writer.print("{d}\n", .{net.score(&base, position.side_to_move)});
        for (args[first_fen + 1 ..]) |fen| {
            var child: Position = undefined;
            var child_info: Position.Info = undefined;
            try readFen(&child, &child_info, fen);
            var layer = base;
            net.update(&layer, &position, &child);
            try stdout_writer.print("{d}\n", .{net.score(&layer, child.side_to_move)});
        }
    } else {
        for (args) |arg| std.log.info("arg: {s}", .{arg});
        position.setStartPosition(&info);
        try stdout_writer.print("{f}\n", .{position});
    }

    try stdout_writer.flush();
}
