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

// TODO: After understanding what is requied a bit more populate this struct.
pub const CastlingRights = struct {};

// ── Tests ──────────────────────────────────────────────────────────────────────

test "Color.opponent is symmetric" {
    try std.testing.expectEqual(Color.black, Color.white.opponent());
    try std.testing.expectEqual(Color.white, Color.black.opponent());
}
