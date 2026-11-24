const std = @import("std");
const Io = std.Io;

const pollock = @import("pollock");
const Move = pollock.Move;
const move_gen = pollock.move_generation;
const MoveList = move_gen.MoveList;
const Position = pollock.Position;

fn readFen(position: *Position, state: *Position.State, fen: []const u8, chess960: bool) !void {
    const rest = try position.setFen(state, fen, chess960);
    if (rest.len != 0) return error.UnexpectedFenSuffix;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var position: Position = undefined;
    var state: Position.State = undefined;

    if (args.len >= 2 and std.mem.eql(u8, args[1], "perft")) {
        if (args.len < 3 or args.len > 4) return error.ExpectedDepthAndOptionalFen;

        const depth = try std.fmt.parseUnsigned(u8, args[2], 10);
        if (args.len == 4)
            try readFen(&position, &state, args[3], false)
        else
            position.setStartPosition(&state);

        try stdout.print("{d}\n", .{pollock.perft.perft(&position, depth)});
    } else {
        position.setStartPosition(&state);
        try stdout.print("{f}\n", .{position});
    }

    try stdout.flush();
}
