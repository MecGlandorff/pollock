const std = @import("std");
const Io = std.Io;

const pollock = @import("pollock");
const Position = pollock.Position;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.info("arg: {s}", .{arg});
    }

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var pos: Position = undefined;
    var state: Position.State = undefined;
    pos.setStartPosition(&state);
    try stdout_writer.print("{f}\n", .{pos});

    pos.setKiwipetePosition(&state);
    try stdout_writer.print("{f}\n", .{pos});

    try stdout_writer.flush();
}
