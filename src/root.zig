//! # Pollock
//!
//! A chess engine library. This root module is the single entry point: it re-exports the types and namespaces that
//! the rest of the engine, and external projects, are meant to use.

// Namespaces.
pub const bitboard = @import("bitboard.zig");
pub const direction = @import("direction.zig");
pub const move_generation = @import("move_generation.zig");
pub const perft = @import("perft.zig");
pub const zobrist = @import("zobrist.zig");
pub const uci_position = @import("uci_position.zig");
pub const uci = @import("uci.zig");
pub const board_eval = @import("board_eval.zig");

// Board geometry.
const board = @import("board.zig");
pub const File = board.File;
pub const Rank = board.Rank;
pub const Square = board.Square;

// Core types.
pub const Castling = @import("castling.zig").Castling;
pub const Color = @import("color.zig").Color;
pub const Move = @import("move.zig").Move;
pub const search = @import("search.zig");
pub const movegen = @import("move_generation.zig");
pub const nnue = @import("nnue.zig");
pub const king_nnue = @import("king_nnue.zig");
pub const wide_nnue = @import("wide_nnue.zig");
pub const Piece = @import("piece.zig").Piece;
pub const Position = @import("Position.zig");

// Utilities.
pub const XorShift64Star = @import("random.zig").XorShift64Star;
pub const ZobristKey = zobrist.ZobristKey;
