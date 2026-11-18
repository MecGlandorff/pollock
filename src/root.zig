//! # Pollock
//!
//! This module provides the public interface to the chess engine.
//! It exposes the core functionality required to represent chess
//! positions, generate and validate moves, evaluate positions, and
//! search for the best moves.
//!
//! The module is intended to serve as an entry point for other Zig
//! projects that wish to use or integrate the engine's functionality.
//! It provides a stable public interface while keeping internal
//! implementation details encapsulated within their respective modules.
//!
//! Only functionality intended for external use is exposed through
//! this module.

pub const chess960 = false;

pub const Bitboard = @import("Bitboard.zig");

const castling = @import("castling.zig");
pub const Castling = castling.Castling;

pub const Color = enum(u1) {
    white = 0,
    black,

    /// Returns the opposite of `color`.
    pub inline fn opposite(color: Color) Color {
        return @fromBackingInt(@backingInt(color) ^ 1);
    }
};

const board = @import("board.zig");
pub const Square = board.Square;
pub const File = board.File;
pub const Rank = board.Rank;

const move = @import("move.zig");
pub const Move = move.Move;

const piece = @import("piece.zig");
pub const Piece = piece.Piece;

pub const Position = @import("Position.zig");

pub const XorShift64Star = @import("random.zig").XorShift64Star;

const zobrist = @import("zobrist.zig");
pub const ZobristKey = zobrist.ZobristKey;
