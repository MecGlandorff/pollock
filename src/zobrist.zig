const std = @import("std");

const pollock = @import("pollock");
const Castling = pollock.Castling;
const File = pollock.File;
const Piece = pollock.Piece;
const Square = pollock.Square;
const Random = pollock.XorShift64Star;

pub const ZobristKey = u64;

const seed: u64 = 0xE2E4_E7E5_D2D4_E5D4;

const Keys = struct {
    piece: std.EnumArray(Piece, std.EnumArray(Square, ZobristKey)),
    castle: [Castling.count]ZobristKey,
    en_passant: std.EnumArray(File, ZobristKey),
    side_to_move: ZobristKey,
};

const keys: Keys = blk: {
    var random: Random = .create(seed);
    var result: Keys = undefined;

    for (&result.piece.values) |*inner| {
        for (&inner.values) |*key| key.* = random.rand();
    }
    for (&result.castle) |*key| key.* = random.rand();
    for (&result.en_passant.values) |*key| key.* = random.rand();
    result.side_to_move = random.rand();

    break :blk result;
};

pub const piece_keys = keys.piece;
pub const castle_keys = keys.castle;
pub const en_passant_keys = keys.en_passant;
pub const side_to_move_key = keys.side_to_move;
