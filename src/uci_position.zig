//! Standard-chess positions and game history received from the UCI client.
const std = @import("std");
const p = @import("pollock");
const Position = p.Position;
const State = Position.State;
const Move = p.Move;
const spaces = " \t\r\n";

pub fn readFen(pos: *Position, state: *State, text: []const u8) ![]const u8 {
    var tokens = std.mem.tokenizeAny(u8, text, spaces);
    var buffer: [256]u8 = undefined;
    var normalized: std.Io.Writer = .fixed(&buffer);
    for (0..6) |index| {
        const field = tokens.next() orelse return error.IncompleteFen;
        if (index != 0) try normalized.writeByte(' ');
        try normalized.writeAll(field);
    }
    // Resolve X-FEN rook letters before checking that the requested rights are orthodox.
    _ = try pos.setFen(state, normalized.buffered(), true);
    for (std.enums.values(p.Color)) |color| {
        for ([_]bool{ true, false }) |kingside| {
            const right = p.Castling.right(color, kingside);
            if (pos.castlingRights().hasAny(right) and
                (pos.kingSquare(color) != p.Square.e1.relative(color) or
                    pos.castlingRookSquare(right) != p.Square.relative(if (kingside) .h1 else .a1, color)))
                return error.UnsupportedChess960;
        }
    }
    pos.chess960 = false;
    if (p.bitboard.baseAttacks(.king, pos.kingSquare(.white)) & pos.kingSquare(.black).bitboard() != 0)
        return error.OpponentInCheck;
    try p.board_eval.validate(pos);
    if (pos.enPassantSquare()) |target| {
        const them = pos.sideToMove().opposite();
        const pushed: p.Square = .fromCoords(target.file(), p.Rank.@"4".relative(them));
        const other_attackers = pos.pieceOccupancy(them, .knight) | (pos.pieceOccupancy(them, .pawn) & ~pushed.bitboard());
        if (pos.checkers() & other_attackers != 0 or !pos.hasLegalEnPassant(target, pushed)) {
            state.en_passant_square = null;
            state.zobrist_key ^= p.zobrist.enPassantKey(target.file());
        }
    }
    return tokens.rest();
}

pub fn name(move: Move, buffer: *[5]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    move.print(false, &writer) catch unreachable;
    return writer.buffered();
}

pub fn findMove(moves: []const Move, uci: []const u8) ?Move {
    var buffer: [5]u8 = undefined;
    for (moves) |move| {
        if (std.mem.eql(u8, name(move, &buffer), uci)) return move;
    }
    return null;
}

pub const Game = struct {
    arena: std.heap.ArenaAllocator,
    board: Position,
    has_moves: bool = false,

    pub fn init(allocator: std.mem.Allocator) Game {
        return .{ .arena = .init(allocator), .board = undefined };
    }

    pub fn deinit(self: *Game) void {
        self.arena.deinit();
    }

    /// Called on a fresh Game. All saved State pointers live for the duration of this game.
    pub fn parse(self: *Game, text: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, text, spaces);
        const kind = tokens.next() orelse return error.InvalidPosition;
        const root = try self.arena.allocator().create(State);
        if (std.mem.eql(u8, kind, "startpos")) {
            self.board.setStartPosition(root);
            try self.extend(tokens.rest());
        } else if (std.mem.eql(u8, kind, "fen")) {
            const rest = try readFen(&self.board, root, tokens.rest());
            try self.extend(rest);
        } else return error.InvalidPosition;
    }

    /// Append only the suffix from a repeated UCI position command. A rejected suffix
    /// leaves the board and its original chain of states available for the next search.
    pub fn extend(self: *Game, text: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, text, spaces);
        if (tokens.peek() == null) return;
        if (!self.has_moves and !std.mem.eql(u8, tokens.next().?, "moves")) return error.ExpectedMoves;
        var counter = tokens;
        var n: usize = 0;
        while (counter.next() != null) n += 1;
        const states = try self.arena.allocator().alloc(State, n);
        errdefer self.arena.allocator().free(states);
        const before = self.board;
        errdefer self.board = before;
        for (states) |*state| {
            var buffer: [Move.max_moves]Move = undefined;
            var moves: p.movegen.MoveList = .initBuffer(&buffer);
            p.movegen.generateLegalMoves(&self.board, &moves, .all);
            const move = findMove(moves.items, tokens.next().?) orelse return error.IllegalMove;
            self.board.doMove(move, state);
        }
        self.has_moves = true;
    }

    pub fn previousKeys(self: *const Game, buffer: []u64) []const u64 {
        var state = self.board.state.previous_state;
        var i = buffer.len;
        const oldest = buffer.len - @min(self.board.state.halfmove_clock, buffer.len);
        while (i > oldest) {
            const prev = state orelse break;
            i -= 1;
            buffer[i] = prev.zobrist_key;
            state = prev.previous_state;
        }
        return buffer[i..];
    }
};
