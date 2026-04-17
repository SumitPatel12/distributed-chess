//! Holds the shared structures that are required across multiple modules.

const std = @import("std");

pub const Color = enum {
    white,
    black,

    pub fn opponent(self: Color) Color {
        const result: Color = switch (self) {
            .white => .black,
            .black => .white,
        };

        std.debug.assert(result != self);
        return result;
    }
};

pub const Position = struct {
    rank: u3,
    file: u3,
};

pub const Move = struct {
    from: Position,
    to: Position,
};

// ── Tests ──────────────────────────────────────────────────────────────────────

test "Color.opponent is symmetric" {
    try std.testing.expectEqual(Color.black, Color.white.opponent());
    try std.testing.expectEqual(Color.white, Color.black.opponent());
}
