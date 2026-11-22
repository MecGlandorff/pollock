const std = @import("std");

const pollock = @import("pollock");
const bitboard = pollock.bitboard;
const Bitboard = bitboard.Bitboard;
const Castling = pollock.Castling;
const Color = pollock.Color;
const direction = pollock.direction;
const Direction = direction.Direction;
const File = pollock.File;
const Move = pollock.Move;
const Position = pollock.Position;
const Rank = pollock.Rank;
const Square = pollock.Square;

pub fn pseudolegalMoves(
    position: *const Position,
    comptime side_to_move: Color,
    move_list: *std.ArrayList(Move),
) void {
    const opponent = side_to_move.opposite();
    const up = if (side_to_move == .white) direction.north else direction.south;
    const rank3 = Rank.@"3".relative(side_to_move);
    const rank7 = Rank.@"7".relative(side_to_move);

    // All squares without one of our own pieces are potential targets.
    var target = ~position.colorOccupancy(side_to_move);

    // Regular king moves.
    const king_square = position.kingSquare(side_to_move);
    splatPieceMoves(move_list, bitboard.baseAttacks(.king, king_square) & target, king_square);

    const checkers = position.checkers();

    // If we are in double check, only non-castling king moves can get us out of check.
    if (bitboard.popcountGreaterThanOne(checkers))
        return;

    // If not in check, castling moves should be generated. Else, we update the target such that each move will either
    // interpose the check or capture the checker (we have already computed king moves).
    if (checkers == bitboard.empty) {
        const castling_rights = position.castlingRights();
        const kingside: Castling = .right(side_to_move, true);
        const queenside: Castling = .right(side_to_move, false);

        if (castling_rights.has(kingside) and !position.castlingObstructed(kingside))
            move_list.appendAssumeCapacity(.createCastle(position, side_to_move, true));
        if (castling_rights.has(queenside) and !position.castlingObstructed(queenside))
            move_list.appendAssumeCapacity(.createCastle(position, side_to_move, false));
    } else {
        target = bitboard.between(king_square, bitboard.lsb(checkers));
    }

    // Pawn moves.
    const friendly = position.pieceOccupancy(side_to_move, .pawn);
    const non_promotion = friendly & ~rank7.bitboard();
    var empty_squares = ~position.totalOccupancy();

    // Pawn pushes.
    var push_once = bitboard.shift(non_promotion, up) & empty_squares;
    empty_squares &= target;
    const push_twice = bitboard.shift(push_once & rank3.bitboard(), up) & empty_squares;
    push_once &= target;
    splatPawnMoves(move_list, push_once, up);
    splatPawnMoves(move_list, push_twice, 2 * up);
}

fn splatPieceMoves(move_list: *std.ArrayList(Move), attacks: Bitboard, source: Square) void {
    var attacks_left = attacks;
    while (attacks_left != bitboard.empty)
        move_list.appendAssumeCapacity(.createNormal(source, bitboard.popLsb(&attacks_left)));
}

fn splatPawnMoves(move_list: *std.ArrayList(Move), pawn_moves: Bitboard, dir: Direction) void {
    var moves = pawn_moves;
    while (moves != bitboard.empty) {
        const destination = bitboard.popLsb(&moves);
        move_list.appendAssumeCapacity(.createNormal(destination.step(-dir), destination));
    }
}
