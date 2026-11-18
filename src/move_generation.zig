const std = @import("std");

const pollock = @import("pollock");
const Color = pollock.Color;
const Move = pollock.Move;
const Position = pollock.Position;

pub fn pseudolegalMoves(position: *const Position, comptime side_to_move: Color) []Move {
    const move_list_buffer: [Move.max_moves]Move = undefined;
    var move_list: std.ArrayList(Move) = .initBuffer(&move_list_buffer);

    const opponent = side_to_move.opposite();

    // All squares without one of our own pieces are potential targets.
    const target = ~position.colorOccupancy(side_to_move);

    // Regular king moves.
    
}
