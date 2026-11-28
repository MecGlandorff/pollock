const std = @import("std");

const pollock = @import("pollock");
const bitboard = pollock.bitboard;
const Bitboard = bitboard.Bitboard;
const Castling = pollock.Castling;
const Color = pollock.Color;
const dir = pollock.direction;
const Direction = dir.Direction;
const Move = pollock.Move;
const Piece = pollock.Piece;
const Position = pollock.Position;
const Rank = pollock.Rank;
const Square = pollock.Square;

pub const MoveList = std.ArrayList(Move);

/// Selects which legal moves `generateLegalMoves` produces.
pub const GenerationType = enum {
    /// All legal moves when in check.
    evasions,
    /// Captures, including en passant and promotions by capture, plus queen promotions by push.
    captures,
    /// All legal moves. Generates evasions if in check.
    all,
};

/// Appends the legal moves of the side to move in `position` to `moves`, as selected by `generation_type`. The list
/// must have room for `Move.max_moves` more moves. `evasions` requires the side to move to be in check, `captures`
/// requires that it is not.
pub fn generateLegalMoves(
    position: *Position,
    moves: *MoveList,
    comptime generation_type: GenerationType,
) void {
    std.debug.assert(moves.capacity - moves.items.len >= Move.max_moves);

    const checkers = position.checkers();

    if (generation_type == .all and checkers != bitboard.empty) {
        generateLegalMoves(position, moves, .evasions);
        return;
    }

    std.debug.assert((generation_type == .evasions) == (checkers != bitboard.empty));

    const us = position.sideToMove();
    const them = us.opposite();
    const king_square = position.kingSquare(us);

    // Destinations for non-king pieces.
    var target: Bitboard = undefined;

    // In double check only the king can move.
    if (generation_type != .evasions or !bitboard.popcountGreaterThanOne(checkers)) {
        target = switch (generation_type) {
            // Capture the checker or block its line (`between` includes the checker and excludes the king).
            .evasions => bitboard.between(king_square, bitboard.lsb(checkers)),
            .captures => position.colorOccupancy(them),
            .all => ~position.colorOccupancy(us),
        };

        switch (us) {
            .white => generatePawnMoves(position, moves, target, .white, generation_type),
            .black => generatePawnMoves(position, moves, target, .black, generation_type),
        }
        generateMoves(position, moves, target, us, .knight);
        generateMoves(position, moves, target, us, .bishop);
        generateMoves(position, moves, target, us, .rook);
        generateMoves(position, moves, target, us, .queen);
    }

    // The king may escape to any square not occupied by its own pieces.
    if (comptime generation_type == .evasions)
        target = ~position.colorOccupancy(us);

    const king_attacks = bitboard.baseAttacks(.king, king_square) & target;
    appendMoves(moves, king_attacks & ~position.allThreats(), king_square);

    const castling_rights = position.castlingRights();

    if (generation_type == .all and castling_rights.hasAny(Castling.all)) {
        for ([_]bool{ true, false }) |kingside| {
            const castle: Castling = .right(us, kingside);

            if (!castling_rights.hasAny(castle) or position.castlingObstructed(castle))
                continue;

            const rook_square = position.castlingRookSquare(castle);
            const destination: Square = .relative(if (kingside) .g1 else .c1, us);

            // No square the king crosses or lands on may be attacked.
            const path_attackers = bitboard.between(king_square, destination) & position.allThreats() != bitboard.empty;

            // In Chess960 a pinned rook leaving the back rank would expose the king.
            const pinned_rook = position.blockers(us) & rook_square.bitboard() != bitboard.empty;

            if (!path_attackers and !pinned_rook)
                moves.appendAssumeCapacity(.castle(king_square, rook_square));
        }
    }
}

/// Appends the legal moves of the knights, bishops, rooks or queens of `us` to `moves`, limited to `target`.
fn generateMoves(
    position: *const Position,
    moves: *MoveList,
    target: Bitboard,
    us: Color,
    comptime piece_type: Piece.Type,
) void {
    std.debug.assert(piece_type != .pawn and piece_type != .king);

    const occupancy = position.totalOccupancy();
    const pieces = position.pieceOccupancy(us, piece_type);
    const pinned = position.blockers(us);

    var unpinned_pieces = pieces & ~pinned;

    while (unpinned_pieces != bitboard.empty) {
        const source = bitboard.popLsb(&unpinned_pieces);
        const attacks = bitboard.attacks(.fromType(piece_type), source, occupancy) & target;

        appendMoves(moves, attacks, source);
    }

    // A pinned knight can never move, so only sliders need the pinned pass.
    if (comptime piece_type != .knight) {
        const king_square = position.kingSquare(us);

        var pinned_pieces = pieces & pinned;

        while (pinned_pieces != bitboard.empty) {
            const source = bitboard.popLsb(&pinned_pieces);
            const attacks = bitboard.attacks(.fromType(piece_type), source, occupancy) & target;

            // A pinned slider may only move along the line through its king.
            const safe_attacks = attacks & bitboard.line(king_square, source);

            appendMoves(moves, safe_attacks, source);
        }
    }
}

/// Appends a normal move from `source` to each square in `attacks`.
fn appendMoves(
    moves: *MoveList,
    attacks: Bitboard,
    source: Square,
) void {
    var attacks_left = attacks;

    while (attacks_left != bitboard.empty)
        moves.appendAssumeCapacity(.normal(source, bitboard.popLsb(&attacks_left)));
}

/// Appends the legal pawn moves of `us` to `moves`. `target` is only read for evasions.
fn generatePawnMoves(
    position: *const Position,
    moves: *MoveList,
    target: Bitboard,
    comptime us: Color,
    comptime generation_type: GenerationType,
) void {
    const them = us.opposite();
    const forward = if (us == .white) dir.north else dir.south;
    const forward_twice = 2 * forward;
    const right = if (us == .white) dir.east else dir.west;
    const left = -right;
    const forward_right = forward + right;
    const forward_left = forward + left;
    const double_push_rank = Rank.@"3".relative(us); // Rank a pawn lands on after a single push from its start rank.
    const promotion_rank = Rank.@"7".relative(us); // Rank pawns promote from.

    const king_square = position.kingSquare(us);
    const pinned = position.blockers(us);

    // A pinned pawn may only push along the king's file.
    const can_push = ~pinned | king_square.file().bitboard();
    const pawns = position.pieceOccupancy(us, .pawn);

    const regular_pawns = pawns & ~promotion_rank.bitboard();
    const empty = ~position.totalOccupancy();

    // Captures-only generation skips pushes, but still gets queen promotions below.
    if (comptime generation_type != .captures) {
        var single_pushes = bitboard.shift(regular_pawns & can_push, forward) & empty;

        // Derived before masking with `target`: the intermediate square only has to be empty.
        var double_pushes = bitboard.shift(single_pushes & double_push_rank.bitboard(), forward) & empty;

        if (comptime generation_type == .evasions) {
            single_pushes &= target;
            double_pushes &= target;
        }

        appendPawnMoves(moves, single_pushes, forward);
        appendPawnMoves(moves, double_pushes, forward_twice);
    }

    // A pinned pawn may only capture along its pin line.
    const can_capture_east = ~pinned | bitboard.diagonal(king_square);
    const can_capture_west = ~pinned | bitboard.antidiagonal(king_square);

    // In check, the only piece a pawn may capture directly is the checker.
    const enemies = if (comptime generation_type == .evasions) position.checkers() else position.colorOccupancy(them);
    const promotion_pawns = pawns & promotion_rank.bitboard();

    if (promotion_pawns != bitboard.empty) {
        var east_captures = bitboard.shift(promotion_pawns & can_capture_east, forward_right) & enemies;
        var west_captures = bitboard.shift(promotion_pawns & can_capture_west, forward_left) & enemies;
        var single_pushes = bitboard.shift(promotion_pawns & can_push, forward) & empty;

        if (comptime generation_type == .evasions)
            single_pushes &= target;

        while (east_captures != bitboard.empty)
            appendPromotions(moves, bitboard.popLsb(&east_captures), forward_right, true, generation_type);

        while (west_captures != bitboard.empty)
            appendPromotions(moves, bitboard.popLsb(&west_captures), forward_left, true, generation_type);

        while (single_pushes != bitboard.empty)
            appendPromotions(moves, bitboard.popLsb(&single_pushes), forward, false, generation_type);
    }

    // Regular and en passant captures.
    const east_captures = bitboard.shift(regular_pawns & can_capture_east, forward_right) & enemies;
    const west_captures = bitboard.shift(regular_pawns & can_capture_west, forward_left) & enemies;

    appendPawnMoves(moves, east_captures, forward_right);
    appendPawnMoves(moves, west_captures, forward_left);

    // In check, en passant only helps if the captured pawn is the checker or the target blocks the check.
    if (position.enPassantSquare()) |en_passant_square| {
        // If it was a discoverd check, en passant won't help.
        if (generation_type == .evasions and (target & en_passant_square.step(forward).bitboard() != bitboard.empty))
            return;

        std.debug.assert(en_passant_square.rank() == Rank.@"6".relative(us));

        // Our pawns that attack the target square, subject to pins.
        const en_passant_bb = en_passant_square.bitboard();
        const east_attack = can_capture_east & bitboard.shift(en_passant_bb, -forward_right);
        const west_attack = can_capture_west & bitboard.shift(en_passant_bb, -forward_left);
        var en_passant_attackers = regular_pawns & (east_attack | west_attack);

        std.debug.assert(en_passant_attackers != bitboard.empty);

        while (en_passant_attackers != bitboard.empty)
            moves.appendAssumeCapacity(.enPassant(bitboard.popLsb(&en_passant_attackers), en_passant_square));
    }
}

/// Appends a normal move to each square in `attacks`, with the source being the destination moved back by `direction`.
fn appendPawnMoves(
    moves: *MoveList,
    attacks: Bitboard,
    comptime direction: Direction,
) void {
    var pawns_left = attacks;

    while (pawns_left != bitboard.empty) {
        const destination = bitboard.popLsb(&pawns_left);
        const source = destination.step(-direction);

        moves.appendAssumeCapacity(.normal(source, destination));
    }
}

/// Appends the promotions to `destination`, with the source being `destination` moved back by `direction`. Queen
/// promotions are always generated. Underpromotions are generated if `generation_type` is not `captures`, or if
/// `capture` is set.
fn appendPromotions(
    moves: *MoveList,
    destination: Square,
    comptime direction: Direction,
    comptime capture: bool,
    comptime generation_type: GenerationType,
) void {
    const source = destination.step(-direction);

    moves.appendAssumeCapacity(.promotion(source, destination, .queen));

    if ((generation_type == .captures and capture) or generation_type != .captures) {
        moves.appendAssumeCapacity(.promotion(source, destination, .rook));
        moves.appendAssumeCapacity(.promotion(source, destination, .bishop));
        moves.appendAssumeCapacity(.promotion(source, destination, .knight));
    }
}
