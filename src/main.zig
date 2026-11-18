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

    var start_pos: Position = undefined;
    var info: Position.Info = undefined;
    start_pos.setStartPosition(&info);

    try stdout_writer.print("{f}\n", .{start_pos});

    try stdout_writer.flush();
}
