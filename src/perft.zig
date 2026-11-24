const pollock = @import("pollock");

const Move = pollock.Move;
const move_gen = pollock.move_generation;
const MoveList = move_gen.MoveList;
const Position = pollock.Position;

pub fn perft(position: *Position, depth: u8) u64 {
    if (depth == 0) return 1;

    var buffer: [Move.max_moves]Move = undefined;
    var moves: MoveList = .initBuffer(&buffer);
    move_gen.generateLegalMoves(position, &moves, .all);

    if (depth == 1) return moves.items.len;

    var nodes: u64 = 0;
    for (moves.items) |move| {
        var next_state: Position.State = undefined;

        position.doMove(move, &next_state);
        nodes += perft(position, depth - 1);
        position.undoMove(move);
    }

    return nodes;
}
