pub const Color = enum {
    white,
    black,

    pub fn opponent(self: Color) Color {
        if (self == .white) {
            return .black;
        } else {
            return .white;
        }
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
