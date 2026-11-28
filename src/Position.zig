const std = @import("std");

const pollock = @import("pollock");
const bitboard = pollock.bitboard;
const Bitboard = bitboard.Bitboard;
const Castling = pollock.Castling;
const Color = pollock.Color;
const File = pollock.File;
const Move = pollock.Move;
const Piece = pollock.Piece;
const Rank = pollock.Rank;
const Square = pollock.Square;
const zobrist = pollock.zobrist;
const ZobristKey = pollock.ZobristKey;

const Position = @This();

state: *State,
board: std.EnumArray(Square, ?Piece),
type_occupancy: std.EnumArray(Piece.Type, Bitboard),
color_occupancy: std.EnumArray(Color, Bitboard),
/// Rights revoked when a piece moves from or to the square (king and castling rook squares only).
castling_rights_mask: std.EnumArray(Square, Castling),
/// Indexed by `Castling.index()`. Only valid for rights that exist in the position.
castling_rook_square: [Castling.count]Square,
/// Indexed by `Castling.index()`. Only valid for rights that exist in the position.
castling_path: [Castling.count]Bitboard,
game_ply: usize,
side_to_move: Color,
chess960: bool,

/// Per-move state that cannot be recomputed on undo, or is expensive to.
pub const State = struct {
    previous_state: ?*const State,
    /// Opponent pieces giving check to the side to move.
    checkers: Bitboard,
    /// Pieces of either color that are the only piece between an opposing slider and the king of the indexed color.
    blockers: std.EnumArray(Color, Bitboard),
    /// Squares attacked by the opponent, per piece type. Only valid if `all_threats` is not empty (see `allThreats`).
    threats: std.EnumArray(Piece.Type, Bitboard),
    /// Union of `threats`, or empty if they have not been computed yet.
    all_threats: Bitboard,
    castling_rights: Castling,
    captured_piece: ?Piece,
    /// Only set if a pawn can capture there (see `setFen` and `doMove`).
    en_passant_square: ?Square,
    zobrist_key: ZobristKey,
    halfmove_clock: u32,
    /// Number of earlier occurrences of this position in the linked history.
    repetition: u32,
};

/// Returns the square of the king of `color` in `position`. Requires exactly one king of `color`.
pub fn kingSquare(position: *const Position, color: Color) Square {
    std.debug.assert(@popCount(position.pieceOccupancy(color, .king)) == 1);

    return @fromBackingInt(@intCast(@ctz(position.pieceOccupancy(color, .king))));
}

/// Returns the piece on `square` in `position`, or `null` if no piece is present.
pub fn onSquare(position: *const Position, square: Square) ?Piece {
    return position.board.get(square);
}

/// Returns the occupancy of `piece_type` in `position`.
pub fn typeOccupancy(position: *const Position, piece_type: Piece.Type) Bitboard {
    return position.type_occupancy.get(piece_type);
}

/// Returns the occupancy of `color` in `position`.
pub fn colorOccupancy(position: *const Position, color: Color) Bitboard {
    return position.color_occupancy.get(color);
}

/// Returns the occupancy of the pieces of `piece_type` and `color` in `position`.
pub fn pieceOccupancy(position: *const Position, color: Color, piece_type: Piece.Type) Bitboard {
    return position.colorOccupancy(color) & position.typeOccupancy(piece_type);
}

/// Returns the total occupancy in `position`.
pub fn totalOccupancy(position: *const Position) Bitboard {
    return position.colorOccupancy(.white) | position.colorOccupancy(.black);
}

/// Returns the castling rights revoked by a move from or to `square` in `position`.
pub fn castlingRightsMask(position: *const Position, square: Square) Castling {
    return position.castling_rights_mask.get(square);
}

/// Returns the rook square of the `castling_right` in `position`.
pub fn castlingRookSquare(position: *const Position, castling_right: Castling) Square {
    return position.castling_rook_square[castling_right.index()];
}

/// Returns the squares that must be empty to castle with `castling_right` in `position`.
pub fn castlingPath(position: *const Position, castling_right: Castling) Bitboard {
    return position.castling_path[castling_right.index()];
}

/// Returns the color of the side to move in `position`.
pub fn sideToMove(position: *const Position) Color {
    return position.side_to_move;
}

/// Returns the opponent pieces that give check to the side to move in `position`.
pub fn checkers(position: *const Position) Bitboard {
    return position.state.checkers;
}

/// Returns the pieces of either color that are the only piece between an opposing slider and the king of `color` in
/// `position`. Moving such a piece off the line exposes the king, so a blocker of the side to move is pinned, and a
/// blocker of the opponent gives a discovered check when it moves.
pub fn blockers(position: *const Position, color: Color) Bitboard {
    return position.state.blockers.get(color);
}

/// Returns the castling rights that are still available in `position`.
pub fn castlingRights(position: *const Position) Castling {
    return position.state.castling_rights;
}

/// Returns the en passant target square of `position`, or `null` if there is none. The square is only set if a pawn
/// of the side to move can capture there, so it can be `null` right after a double push.
pub fn enPassantSquare(position: *const Position) ?Square {
    return position.state.en_passant_square;
}

/// Returns the Zobrist key of `position`.
pub fn zobristKey(position: *const Position) ZobristKey {
    return position.state.zobrist_key;
}

/// Returns whether any square on the castling path of `castling_right` in `position` is occupied. The castling king
/// and rook themselves are not part of the path. Attacked squares are not considered.
pub fn castlingObstructed(position: *const Position, castling_right: Castling) bool {
    return position.totalOccupancy() & position.castlingPath(castling_right) != bitboard.empty;
}

/// Returns the squares attacked by opponent pieces of `piece_type`, including squares of their own pieces they defend.
/// Sliders see through the king of the side to move. Computed on first use and cached in the state.
pub fn threats(position: *const Position, comptime piece_type: Piece.Type) Bitboard {
    _ = position.allThreats();

    return position.state.threats.get(piece_type);
}

/// Returns the squares attacked by any opponent piece, as in `threats`.
pub fn allThreats(position: *const Position) Bitboard {
    // If not in stalemate, there is always a move and hence an attack.
    if (position.state.all_threats == bitboard.empty)
        position.computeThreats();

    return position.state.all_threats;
}

fn computeThreats(position: *const Position) void {
    const us = position.sideToMove();
    const them = us.opposite();

    // Removing our king makes sliders attack through its square, so it cannot step backwards along a check.
    const occupancy = position.totalOccupancy() ^ position.kingSquare(us).bitboard();

    var all = bitboard.empty;

    inline for (std.enums.values(Piece.Type)) |piece_type| {
        const piece_threats = position.attackedBy(them, piece_type, occupancy);
        position.state.threats.set(piece_type, piece_threats);
        all |= piece_threats;
    }

    position.state.all_threats = all;
}

/// Returns the squares attacked by the pieces of `piece_type` and `color`, with sliders blocked by `occupancy`.
fn attackedBy(position: *const Position, color: Color, comptime piece_type: Piece.Type, occupancy: Bitboard) Bitboard {
    if (comptime piece_type == .pawn) {
        return switch (color) {
            .white => bitboard.pawnAttacks(.white, position.pieceOccupancy(.white, .pawn)),
            .black => bitboard.pawnAttacks(.black, position.pieceOccupancy(.black, .pawn)),
        };
    }

    var pieces = position.pieceOccupancy(color, piece_type);
    var result = bitboard.empty;

    while (pieces != bitboard.empty)
        result |= bitboard.attacks(.fromType(piece_type), bitboard.popLsb(&pieces), occupancy);

    return result;
}

/// Places `piece` on the empty `square` and updates the occupancies and the Zobrist key.
pub fn placePiece(position: *Position, piece: Piece, square: Square) void {
    std.debug.assert(position.onSquare(square) == null);

    const square_bb = square.bitboard();
    position.board.set(square, piece);
    position.type_occupancy.getPtr(piece.type).* |= square_bb;
    position.color_occupancy.getPtr(piece.color).* |= square_bb;

    position.state.zobrist_key ^= zobrist.pieceKey(piece, square);
}

/// Update a single square. On undo the saved parent state already contains its complete key.
fn changePiece(position: *Position, piece: Piece, square: Square, comptime action: enum { put, take }, comptime update_key: bool) void {
    if (action == .put and update_key) return position.placePiece(piece, square);

    std.debug.assert(position.onSquare(square) == if (action == .put) null else @as(?Piece, piece));
    position.board.set(square, if (action == .put) piece else null);
    position.type_occupancy.getPtr(piece.type).* ^= square.bitboard();
    position.color_occupancy.getPtr(piece.color).* ^= square.bitboard();
    if (update_key) position.state.zobrist_key ^= zobrist.pieceKey(piece, square);
}

fn captureSquare(move: Move) Square {
    return if (move.kind == .en_passant) .fromCoords(move.destination.file(), move.source.rank()) else move.destination;
}

fn moveCastlingPieces(position: *Position, move: Move, color: Color, comptime forward: bool) void {
    const kingside = move.source.less(move.destination);
    const king_end: Square = .relative(if (kingside) .g1 else .c1, color);
    const rook_end: Square = .relative(if (kingside) .f1 else .d1, color);
    const king: Piece = .create(color, .king);
    const rook: Piece = .create(color, .rook);

    // A Chess960 king or rook can stay put, cross the other piece or swap squares with it.
    position.changePiece(king, if (forward) move.source else king_end, .take, forward);
    position.changePiece(rook, if (forward) move.destination else rook_end, .take, forward);
    position.changePiece(king, if (forward) king_end else move.source, .put, forward);
    position.changePiece(rook, if (forward) rook_end else move.destination, .put, forward);
}

/// After a legal double push, the pushed pawn would disappear on an en passant capture.
/// Check for sliding attacks on the capturing king with both pawns off their original squares.
pub fn hasLegalEnPassant(position: *const Position, target: Square, pushed: Square) bool {
    const us = position.sideToMove();
    const them = us.opposite();
    var candidates = bitboard.baseAttacks(.forPawn(them), target) & position.pieceOccupancy(us, .pawn);
    if (candidates == bitboard.empty) return false;

    const king = position.kingSquare(us);
    const occupancy = (position.totalOccupancy() ^ pushed.bitboard()) | target.bitboard();
    const queens = position.pieceOccupancy(them, .queen);
    const bishops = position.pieceOccupancy(them, .bishop) | queens;
    const rooks = position.pieceOccupancy(them, .rook) | queens;
    while (candidates != bitboard.empty) {
        const source = bitboard.popLsb(&candidates);
        const diagonal, const straight = bitboard.bishopRookAttacks(king, occupancy ^ source.bitboard());
        if ((diagonal & bishops) | (straight & rooks) == bitboard.empty) return true;
    }
    return false;
}

/// Count prior occurrences with the same side to move since the last pawn move or capture.
fn repetitionCount(state: *const State) u32 {
    var cursor = state;
    var remaining = state.halfmove_clock;
    while (remaining >= 2) : (remaining -= 2) {
        const previous = cursor.previous_state orelse break;
        cursor = previous.previous_state orelse break;
        if (cursor.zobrist_key == state.zobrist_key) return cursor.repetition + 1;
    }
    return 0;
}

/// Play a legal, non-null move. The caller owns one distinct state per ply until the move is undone.
pub fn doMove(position: *Position, move: Move, next: *State) void {
    const previous = position.state;
    const us = position.sideToMove();
    std.debug.assert(!move.isNull() and next != previous);
    const mover = position.onSquare(move.source).?;
    std.debug.assert(mover.color == us);

    const captured = if (move.kind == .castle) null else position.onSquare(captureSquare(move));
    next.* = .{
        .previous_state = previous,
        .checkers = undefined,
        .blockers = .initUndefined(),
        .threats = .initUndefined(),
        .all_threats = bitboard.empty,
        .castling_rights = previous.castling_rights,
        .captured_piece = captured,
        .en_passant_square = null,
        .zobrist_key = previous.zobrist_key ^ zobrist.side_to_move_key,
        .halfmove_clock = if (mover.type == .pawn or captured != null) 0 else previous.halfmove_clock + 1,
        .repetition = 0,
    };
    position.state = next;
    if (previous.en_passant_square) |square| next.zobrist_key ^= zobrist.enPassantKey(square.file());

    next.castling_rights.removeRights(position.castlingRightsMask(move.source));
    next.castling_rights.removeRights(position.castlingRightsMask(move.destination));
    if (next.castling_rights != previous.castling_rights)
        next.zobrist_key ^= zobrist.castleKey(previous.castling_rights) ^ zobrist.castleKey(next.castling_rights);

    if (move.kind == .castle) {
        position.moveCastlingPieces(move, us, true);
    } else {
        if (captured) |piece| position.changePiece(piece, captureSquare(move), .take, true);
        position.changePiece(mover, move.source, .take, true);
        const arrival: Piece = if (move.kind == .promotion) .create(us, move.promotionType()) else mover;
        position.placePiece(arrival, move.destination);
    }
    position.side_to_move = us.opposite();
    position.game_ply += 1;
    next.checkers = position.computeCheckers(position.side_to_move);
    next.blockers.set(.white, position.computeBlockers(.white));
    next.blockers.set(.black, position.computeBlockers(.black));

    // A double pawn push changes exactly rank bit 1 (16 in the square index).
    if (mover.type == .pawn and @backingInt(move.source) ^ @backingInt(move.destination) == 16) {
        const target: Square = .fromCoords(move.destination.file(), Rank.@"3".relative(us));
        if (position.hasLegalEnPassant(target, move.destination)) {
            next.en_passant_square = target;
            next.zobrist_key ^= zobrist.enPassantKey(target.file());
        }
    }
    next.repetition = repetitionCount(next);
}

/// Take back the last move and restore its saved state, including the parent attack cache.
pub fn undoMove(position: *Position, move: Move) void {
    const current = position.state;
    const us = position.sideToMove().opposite();
    if (move.kind == .castle) {
        position.moveCastlingPieces(move, us, false);
    } else {
        const arrival = position.onSquare(move.destination).?;
        const mover: Piece = if (move.kind == .promotion) .create(us, .pawn) else arrival;
        position.changePiece(arrival, move.destination, .take, false);
        position.changePiece(mover, move.source, .put, false);
        if (current.captured_piece) |piece| position.changePiece(piece, captureSquare(move), .put, false);
    }
    position.side_to_move = us;
    position.game_ply -= 1;
    // doMove linked the mutable Position.state as read-only history.
    position.state = @constCast(current.previous_state.?);
}

/// Pass the turn for null-move pruning. The current player must be out of check.
/// The search clock starts a new repetition window at this artificial position.
pub fn doNullMove(position: *Position, next: *State) void {
    const previous = position.state;
    std.debug.assert(position.checkers() == bitboard.empty and next != previous);
    var key = previous.zobrist_key ^ zobrist.side_to_move_key;
    if (previous.en_passant_square) |square| key ^= zobrist.enPassantKey(square.file());
    next.* = .{
        .previous_state = previous,
        .checkers = bitboard.empty,
        .blockers = previous.blockers,
        .threats = .initUndefined(),
        .all_threats = bitboard.empty,
        .castling_rights = previous.castling_rights,
        .captured_piece = null,
        .en_passant_square = null,
        .zobrist_key = key,
        .halfmove_clock = 0,
        .repetition = 0,
    };
    position.state = next;
    position.side_to_move = position.sideToMove().opposite();
    position.game_ply += 1;
}

pub fn undoNullMove(position: *Position) void {
    position.state = @constCast(position.state.previous_state.?);
    position.side_to_move = position.sideToMove().opposite();
    position.game_ply -= 1;
}

/// Returns the pieces of the opponent of `color` that give check to the king of `color`.
fn computeCheckers(position: *const Position, color: Color) Bitboard {
    const king_square = position.kingSquare(color);
    const occupancy = position.totalOccupancy();
    const queens = position.typeOccupancy(.queen);

    const bishop_attacks, const rook_attacks = bitboard.bishopRookAttacks(king_square, occupancy);

    // Reverse lookup: attacks are computed from the king's square and intersected with the piece types. Pawn attacks
    // use `color`'s own direction, since a checking pawn stands where our pawn on the king square would attack.
    // No king term: a king can't give check.
    const attackers =
        (bitboard.baseAttacks(.forPawn(color), king_square) & position.typeOccupancy(.pawn)) |
        (bitboard.baseAttacks(.knight, king_square) & position.typeOccupancy(.knight)) |
        (bishop_attacks & (position.typeOccupancy(.bishop) | queens)) |
        (rook_attacks & (position.typeOccupancy(.rook) | queens));

    // Remove our own pieces.
    return attackers & position.colorOccupancy(color.opposite());
}

/// Returns the pieces of either color that are the only piece between an opposing slider and the king of `color`.
fn computeBlockers(position: *const Position, color: Color) Bitboard {
    const king_square = position.kingSquare(color);
    const queens = position.typeOccupancy(.queen);

    // Only sliders can pin. Candidates are the opposing sliders that would attack the king on an empty board.
    const bishop_pinners = bitboard.baseAttacks(.bishop, king_square) & (position.typeOccupancy(.bishop) | queens);
    const rook_pinners = bitboard.baseAttacks(.rook, king_square) & (position.typeOccupancy(.rook) | queens);
    var pinners = (bishop_pinners | rook_pinners) & position.colorOccupancy(color.opposite());

    // `between` includes the king's square, which is not a blocker.
    const blocker_mask = position.totalOccupancy() ^ king_square.bitboard();
    var blockers_bb = bitboard.empty;
    while (pinners != bitboard.empty) {
        const pinner_square = bitboard.popLsb(&pinners);
        const potential_blockers = bitboard.between(pinner_square, king_square) & blocker_mask;

        // Exactly one piece in between is a blocker. With none the king is in check, with two or more nothing is
        // pinned.
        if (!bitboard.popcountGreaterThanOne(potential_blockers))
            blockers_bb |= potential_blockers;
    }

    return blockers_bb;
}

/// Registers the castling right of `color` that uses the rook on `rook_source`. The king must be on the same rank as
/// the rook. Works for standard chess and Chess960 alike.
fn addCastlingRight(position: *Position, color: Color, rook_source: Square) void {
    const king_source = position.kingSquare(color);
    const kingside = king_source.less(rook_source);

    const right: Castling = .right(color, kingside);
    const index = right.index();

    position.state.castling_rights.addRights(right);

    // Moving the king or the rook, or capturing the rook, revokes the right.
    position.castling_rights_mask.getPtr(king_source).addRights(right);
    position.castling_rights_mask.getPtr(rook_source).addRights(right);
    position.castling_rook_square[index] = rook_source;

    // Castling always ends with the king on g1/c1 and the rook on f1/d1 (relative to `color`).
    const king_destination: Square = .relative(if (kingside) .g1 else .c1, color);
    const rook_destination: Square = .relative(if (kingside) .f1 else .d1, color);

    // Squares both pieces travel over or land on must be empty, except for the castling pieces themselves.
    // (`between` excludes its first argument and includes its second.)
    const travelled = bitboard.between(king_source, king_destination) | bitboard.between(rook_source, rook_destination);
    position.castling_path[index] = travelled & ~(king_source.bitboard() | rook_source.bitboard());
}

/// Errors reported by `setFen`. Only malformed text and positions that would break the engine's assumptions are
/// rejected, not every unreachable position.
pub const FenError = error{
    /// Malformed castling field (impossible rights are dropped silently instead).
    InvalidCastling,
    /// Malformed en passant square, or one that is inconsistent with the pieces.
    InvalidEnPassant,
    InvalidPiece,
    /// Wrong number of ranks or files.
    InvalidPlacement,
    InvalidSideToMove,
    InvalidHalfmoveClock,
    InvalidFullmoveNumber,
    MissingKing,
    /// The side that is not to move is in check.
    OpponentInCheck,
    PawnOnBackRank,
    TooManyKings,
    /// The input ended before the field was complete.
    UnexpectedEnd,
};

/// Parses a FEN from the start of `input` and returns the unconsumed rest, e.g. " moves e2e4 e7e5". Fields must be
/// separated by exactly one space.
///
/// Castling accepts `KQkq` (X-FEN: the outermost rook) and Shredder-FEN file letters. Rights that cannot be valid are
/// dropped. If `chess960` is false, this includes rights that don't use the standard king and rook squares.
///
/// On error, `position` is left in an unspecified (partially filled) state.
pub fn setFen(
    position: *Position,
    state: *State,
    input: []const u8,
    chess960: bool,
) FenError![]const u8 {
    // `index` points at the next unread byte, so after an error it is the offset to report.
    var cursor: struct {
        input: []const u8,
        index: usize = 0,

        fn next(c: *@This()) FenError!u8 {
            if (c.index >= c.input.len)
                return FenError.UnexpectedEnd;

            defer c.index += 1;

            return c.input[c.index];
        }
    } = .{ .input = input };

    state.* = .{
        .previous_state = null,
        .checkers = bitboard.empty,
        .blockers = .initFill(bitboard.empty),
        .threats = .initUndefined(),
        .all_threats = bitboard.empty,
        .castling_rights = .none,
        .captured_piece = null,
        .en_passant_square = null,
        .zobrist_key = 0,
        .halfmove_clock = undefined, // Set below.
        .repetition = 0,
    };

    position.* = .{
        .state = state,
        .board = .initFill(null),
        .type_occupancy = .initFill(bitboard.empty),
        .color_occupancy = .initFill(bitboard.empty),
        .castling_rights_mask = .initFill(.none),
        .castling_rook_square = @splat(undefined), // Only read for rights that are set.
        .castling_path = @splat(undefined), // Only read for rights that are set.
        .side_to_move = undefined, // Set below.
        .game_ply = undefined, // Set below.
        .chess960 = chess960,
    };

    // 1. Piece placement. Piece keys are added to the Zobrist key by `placePiece`.
    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    var rank = ranks.next().?;
    var file_count: usize = 0; // May reach 8, which `File` cannot represent.
    while (true) switch (try cursor.next()) {
        ' ' => break,
        '/' => {
            if (file_count != File.count)
                return FenError.InvalidPlacement;

            rank = ranks.next() orelse
                return FenError.InvalidPlacement;
            file_count = 0;
        },
        '1'...'8' => |char| {
            file_count += char - '0';

            if (file_count > File.count)
                return FenError.InvalidPlacement;
        },
        else => |char| {
            if (file_count >= File.count)
                return FenError.InvalidPlacement;

            const piece = Piece.fromChar(char) orelse
                return FenError.InvalidPiece;

            // Movegen assumes pawns never stand on a back rank.
            if (piece.type == .pawn and (rank == .@"1" or rank == .@"8"))
                return FenError.PawnOnBackRank;

            position.placePiece(piece, .fromCoords(@fromBackingInt(@intCast(file_count)), rank));
            file_count += 1;
        },
    };

    if (rank != .@"1" or file_count != File.count)
        return FenError.InvalidPlacement;

    // Exactly one king per side, which makes `kingSquare` safe from here on.
    for (std.enums.values(Color)) |color| {
        switch (@popCount(position.pieceOccupancy(color, .king))) {
            0 => return FenError.MissingKing,
            1 => {},
            else => return FenError.TooManyKings,
        }
    }

    // 2. Side to move.
    position.side_to_move = switch (try cursor.next()) {
        'w' => .white,
        'b' => .black,
        else => return FenError.InvalidSideToMove,
    };

    if (position.side_to_move == .black)
        state.zobrist_key ^= zobrist.side_to_move_key;

    if (try cursor.next() != ' ')
        return FenError.InvalidSideToMove;

    // 3. Castling rights: `-`, or any of `KQkq` and file letters `A-Ha-h`.
    const castling_start = cursor.index;
    while (true) {
        const char = try cursor.next();

        if (char == ' ') {
            // Empty field (e.g. two consecutive spaces). No rights must be written as `-`.
            if (cursor.index == castling_start + 1)
                return FenError.InvalidCastling;
            break;
        }

        if (char == '-') {
            // Only valid as the entire field.
            if (cursor.index != castling_start + 1 or try cursor.next() != ' ')
                return FenError.InvalidCastling;
            break;
        }

        // Syntax errors are rejected, but rights that are merely impossible are skipped below.
        const lower = std.ascii.toLower(char);
        switch (lower) {
            'k', 'q', 'a'...'h' => {},
            else => return FenError.InvalidCastling,
        }

        const color: Color = if (std.ascii.isUpper(char)) .white else .black;
        const back_rank = Rank.@"1".relative(color);
        const king_square = position.kingSquare(color);

        // A king that can castle stands on files b-g of its back rank.
        if (king_square.rank() != back_rank or king_square.file() == .a or king_square.file() == .h)
            continue;

        // `between` excludes the king's square and includes the edge.
        const rooks = (switch (lower) {
            'k' => bitboard.between(king_square, Square.h1.relative(color)),
            'q' => bitboard.between(king_square, Square.a1.relative(color)),
            else => Square.fromCoords(File.fromChar(lower).?, back_rank).bitboard(),
        }) & position.pieceOccupancy(color, .rook);

        if (rooks == bitboard.empty)
            continue;

        // Outermost rook: highest square kingside, lowest queenside. A file letter leaves a single candidate.
        const rook_square: Square = if (lower == 'k') bitboard.msb(rooks) else bitboard.lsb(rooks);

        if (!chess960 and (king_square != Square.e1.relative(color) or
            rook_square != Square.relative(if (king_square.less(rook_square)) .h1 else .a1, color)))
            continue;

        // Duplicate rights (e.g. `KK`) are idempotent.
        position.addCastlingRight(color, rook_square);
    }

    // One key per combination of rights, so this must come after all rights are known.
    state.zobrist_key ^= zobrist.castleKey(state.castling_rights);

    // 4. En passant target square (the square behind a pawn that just double-pushed).
    const en_passant_char = try cursor.next();
    if (en_passant_char == '-') {
        if (try cursor.next() != ' ')
            return FenError.InvalidEnPassant;
    } else {
        const en_passant_file = File.fromChar(en_passant_char) orelse
            return FenError.InvalidEnPassant;

        // The double-pushed pawn belongs to the side that is not to move.
        const us = position.side_to_move;
        const expected_rank: Rank = if (us == .white) .@"6" else .@"3";
        if (Rank.fromChar(try cursor.next()) != expected_rank)
            return FenError.InvalidEnPassant;
        if (try cursor.next() != ' ')
            return FenError.InvalidEnPassant;

        const target: Square = .fromCoords(en_passant_file, expected_rank);
        const start: Square = .fromCoords(en_passant_file, if (us == .white) .@"7" else .@"2"); // Where the pawn came from.
        const pushed: Square = .fromCoords(en_passant_file, if (us == .white) .@"5" else .@"4"); // Where it stands now.

        // Inconsistent setups are ignored rather than rejected, so doMove/undoMove never capture a missing pawn.
        if (position.onSquare(target) == null and
            position.onSquare(start) == null and
            position.onSquare(pushed) == Piece.create(us.opposite(), .pawn))
        {
            // Keep the square only if one of our pawns can attack it, so equal positions get equal Zobrist keys. This
            // must match the rule `doMove` uses when it sets the square.
            const attackers = bitboard.baseAttacks(Piece.AttackType.forPawn(us.opposite()), target) &
                position.pieceOccupancy(us, .pawn);
            if (attackers != bitboard.empty) {
                state.en_passant_square = target;
                state.zobrist_key ^= zobrist.enPassantKey(en_passant_file);
            }
        }
    }

    // 5. Halfmove clock. The 50-move rule allows a draw claim at 100 plies, the 75-move rule ends the game at 150.
    const halfmove_end = std.mem.indexOfScalarPos(u8, input, cursor.index, ' ') orelse
        return FenError.UnexpectedEnd;
    const halfmove = std.fmt.parseUnsigned(u32, input[cursor.index..halfmove_end], 10) catch
        return FenError.InvalidHalfmoveClock;
    if (halfmove > 150)
        return FenError.InvalidHalfmoveClock;

    state.halfmove_clock = halfmove;
    cursor.index = halfmove_end + 1;

    // 6. Fullmove number, ending at the next space or the end of input. Zero is tolerated and treated as one.
    const fullmove_end = std.mem.indexOfScalarPos(u8, input, cursor.index, ' ') orelse input.len;
    const fullmove = std.fmt.parseUnsigned(u32, input[cursor.index..fullmove_end], 10) catch
        return FenError.InvalidFullmoveNumber;

    position.game_ply = 2 * (@as(usize, @max(fullmove, 1)) - 1) + @intFromBool(position.side_to_move == .black);

    state.checkers = position.computeCheckers(position.side_to_move);

    if (position.computeCheckers(position.side_to_move.opposite()) != bitboard.empty)
        return FenError.OpponentInCheck;

    state.blockers.set(.white, position.computeBlockers(.white));
    state.blockers.set(.black, position.computeBlockers(.black));

    // TODO: Drop the en passant square (and its Zobrist key) if no capture is legal, to match `doMove`.

    return input[fullmove_end..];
}

pub fn setStartPosition(position: *Position, state: *State) void {
    _ = setFen(position, state, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", false) catch unreachable;
}

pub fn setKiwipetePosition(position: *Position, state: *State) void {
    _ = setFen(position, state, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", false) catch unreachable;
}

/// Writes `position` as FEN. Castling rights are written as `KQkq`, or as Shredder-FEN file letters if
/// `position.chess960` is set.
pub fn writeFen(position: *const Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // 1. Piece placement, rank 8 down to rank 1.
    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        if (rank != .@"8")
            try writer.writeByte('/');

        var empty_count: u8 = 0;
        for (std.enums.values(File)) |file| {
            const piece = position.onSquare(.fromCoords(file, rank)) orelse {
                empty_count += 1;
                continue;
            };

            if (empty_count > 0) {
                try writer.writeByte('0' + empty_count);
                empty_count = 0;
            }
            try writer.writeByte(piece.toChar());
        }

        if (empty_count > 0)
            try writer.writeByte('0' + empty_count);
    }

    // 2. Side to move.
    try writer.writeAll(if (position.side_to_move == .white) " w " else " b ");

    // 3. Castling rights, in the order KQkq.
    const rights = position.state.castling_rights;
    if (rights == Castling.none) {
        try writer.writeByte('-');
    } else {
        for (std.enums.values(Color)) |color| {
            for ([_]bool{ true, false }) |kingside| {
                const right: Castling = .right(color, kingside);

                if (!rights.hasAny(right))
                    continue;

                const char: u8 = if (position.chess960)
                    @tagName(position.castlingRookSquare(right).file())[0]
                else if (kingside) 'k' else 'q';

                try writer.writeByte(if (color == .white) std.ascii.toUpper(char) else char);
            }
        }
    }
    try writer.writeByte(' ');

    // 4. En passant square.
    if (position.state.en_passant_square) |square| {
        try writer.print("{s}{s}", .{ @tagName(square.file()), @tagName(square.rank()) });
    } else {
        try writer.writeByte('-');
    }

    // 5/6. Halfmove clock and fullmove number.
    try writer.print(" {d} {d}", .{ position.state.halfmove_clock, position.game_ply / 2 + 1 });
}

/// Prints a board diagram, the FEN and the Zobrist key.
pub fn format(position: *const Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const separator = "+---+---+---+---+---+---+---+---+\n";

    try writer.writeAll(separator);

    var ranks = std.mem.reverseIterator(std.enums.values(Rank));
    while (ranks.next()) |rank| {
        for (std.enums.values(File)) |file| {
            const piece = position.onSquare(.fromCoords(file, rank));
            try writer.print("| {c} ", .{if (piece) |p| p.toChar() else ' '});
        }

        try writer.print("| {s}\n" ++ separator, .{@tagName(rank)});
    }

    try writer.writeAll("  a   b   c   d   e   f   g   h\nFEN: ");
    try position.writeFen(writer);
    try writer.print("\nZobrist Hash: 0x{x:0>16}", .{position.state.zobrist_key});
}
