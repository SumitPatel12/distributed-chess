//! Holds the shared structures that are required across multiple modules.

const std = @import("std");

/// Color of the player, either black or white.
pub const Color = enum {
    white,
    black,

    pub fn opponent(self: Color) Color {
        return switch (self) {
            .white => .black,
            .black => .white,
        };
    }
};

// Now that some of this is build up, I can say one thing. u3 while encodes the range correctly is a
// bit difficult when doing a bounds check since we cna't go less then 0, and greater that 8 we end
// up having to int cast for bounds check, which is likely not ideal.
/// Models the position of a piece on the board as rank, file pair. Indexed from 0-7 for both.
pub const Position = struct {
    rank: u3,
    file: u3,
};

/// Models a piece move, as `from` to `to`.
pub const Move = struct {
    from: Position,
    to: Position,
};

/// Holds the castling rights validity for both sides. Defaults to true for all 4.
pub const CastlingRights = struct {
    white_kingside: bool = true,
    white_queenside: bool = true,
    black_kingside: bool = true,
    black_queenside: bool = true,
};

// ── Tests ──────────────────────────────────────────────────────────────────────

test "Color.opponent is symmetric" {
    try std.testing.expectEqual(Color.black, Color.white.opponent());
    try std.testing.expectEqual(Color.white, Color.black.opponent());
}
