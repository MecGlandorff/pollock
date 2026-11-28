const std = @import("std");

const pollock = @import("pollock");
const File = pollock.File;
const Square = pollock.Square;

pub const Direction = @Int(.signed, @bitSizeOf(Square.SquareInt) + 1);

pub const north: Direction = File.count;
pub const south: Direction = -north;
pub const east: Direction = 1;
pub const west: Direction = -east;
pub const northeast: Direction = north + east;
pub const northwest: Direction = north + west;
pub const southeast: Direction = south + east;
pub const southwest: Direction = south + west;
