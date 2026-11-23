const std = @import("std");
const Io = std.Io;

const pollock = @import("pollock");
const Move = pollock.Move;
const move_gen = pollock.move_generation;
const MoveList = move_gen.MoveList;
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

    var buffer: [pollock.Move.max_moves]Move = undefined;
    var moves: MoveList = .initBuffer(&buffer);
    move_gen.generateLegalMoves(&pos, &moves, .all);

    try stdout_writer.print("{d}\n", .{moves.items.len});
    for (moves.items) |move| {
        try move.print(false, stdout_writer);
        try stdout_writer.writeByte('\n');
    }

    moves.clearRetainingCapacity();

    pos.setKiwipetePosition(&state);
    try stdout_writer.print("{f}\n", .{pos});
    move_gen.generateLegalMoves(&pos, &moves, .all);

    try stdout_writer.print("{d}\n", .{moves.items.len});
    for (moves.items) |move| {
        try move.print(false, stdout_writer);
        try stdout_writer.writeByte('\n');
    }

    try stdout_writer.flush();
}
