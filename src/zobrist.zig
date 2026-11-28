const std = @import("std");

const pollock = @import("pollock");
const Castling = pollock.Castling;
const File = pollock.File;
const Piece = pollock.Piece;
const Square = pollock.Square;
const Random = pollock.XorShift64Star;

/// A 64-bit Zobrist hash of a position.
pub const ZobristKey = u64;

/// Fixed seed, so keys (and therefore bench signatures and opening book hashes) are reproducible across builds.
const seed: u64 = 0xE2E4_E7E5_D2D4_E5D4;

/// Random keys for every feature of a position. A position's key is the XOR of the keys of its features.
const Keys = struct {
    /// `[piece index][square]`.
    piece: [Piece.count]std.EnumArray(Square, ZobristKey),
    /// Indexed by the whole set of rights (`Castling.index()`), not by single rights.
    castle: [Castling.count]ZobristKey,
    /// Only the file matters, since the rank follows from the side to move.
    en_passant: std.EnumArray(File, ZobristKey),
    /// XORed in when black is to move.
    side_to_move: ZobristKey,
};

const keys: Keys = blk: {
    @setEvalBranchQuota(1_000_000);

    var random: Random = .create(seed);
    var result: Keys = undefined;

    for (&result.piece) |*inner| {
        for (&inner.values) |*key| key.* = random.rand();
    }
    for (&result.castle) |*key| key.* = random.rand();
    for (&result.en_passant.values) |*key| key.* = random.rand();
    result.side_to_move = random.rand();

    break :blk result;
};

/// Key to XOR in when black is to move, and on every move to toggle the side to move.
pub const side_to_move_key = keys.side_to_move;

/// Returns the key of `piece` standing on `square`.
pub inline fn pieceKey(piece: Piece, square: Square) ZobristKey {
    return keys.piece[piece.index()].get(square);
}

/// Returns the key of the set of castling rights `castle`. To update after a move, XOR out the old set and XOR in the
/// new one.
pub inline fn castleKey(castle: Castling) ZobristKey {
    return keys.castle[castle.index()];
}

/// Returns the key of an en passant square on `file`.
pub inline fn enPassantKey(file: File) ZobristKey {
    return keys.en_passant.get(file);
}
