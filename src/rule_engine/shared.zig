//! Classification: engine-core
//! Shared structs and constants for the ruling engine.

const std = @import("std");
const shared = @import("../shared.zig");
const Color = shared.Color;
const Position = shared.Position;
const Move = shared.Move;
const Board = @import("../board.zig").Board;
const Piece = @import("../board.zig").Piece;
const BoundedArray = @import("../bounded_array.zig").BoundedArray;

pub const MAX_LEGAL_MOVES: usize = 256;

pub const WHITE_KING_HOME_POSITION: Position = .{ .rank = 0, .file = 4 };
pub const BLACK_KING_HOME_POSITION: Position = .{ .rank = 7, .file = 4 };

// That extra line gives better formatting on the hovered definition.
/// Direction of movement on the board.
///
///     north = increasing rank (1->8, toward black)
///     south = decreasing rank (8->1, toward white)
///     east = increasing file (a->h, kingside for white)
///     west = decreasing file (h->a, queenside for white)
pub const Direction = enum {
    north,
    south,
    east,
    west,
    north_east,
    north_west,
    south_east,
    south_west,

    // I'm not sure if i2 has any benefits other than trimming down the thing, since zig gives the
    // option I'm using it.
    //
    // TODO: Check what are the implications if any of using i2.
    /// Returns the delta for navigation in that direction.
    pub fn deltas(self: Direction) struct { rank: i2, file: i2 } {
        return switch (self) {
            .north => .{ .rank = 1, .file = 0 },
            .south => .{ .rank = -1, .file = 0 },
            .east => .{ .rank = 0, .file = 1 },
            .west => .{ .rank = 0, .file = -1 },
            .north_east => .{ .rank = 1, .file = 1 },
            .north_west => .{ .rank = 1, .file = -1 },
            .south_east => .{ .rank = -1, .file = 1 },
            .south_west => .{ .rank = -1, .file = -1 },
        };
    }
};

pub const ROOK_DIRECTIONS: [4]Direction = .{ .north, .south, .east, .west };

pub const BISHOP_DIRECTIONS: [4]Direction = .{ .north_east, .north_west, .south_east, .south_west };

pub const ALL_DIRECTIONS: [8]Direction = .{ .north, .south, .east, .west, .north_east, .north_west, .south_east, .south_west };

// Knights are special since they jump pieces not slide, so ray-tracing type of thing that we do for
// the other pieces will not work for this.
// Knight moves are L-shaped: 2 squares in one axis, 1 in the other. So their delta will be +-1/+-2.
pub const KNIGHT_OFFSETS: [8]struct { rank: i3, file: i3 } = .{
    .{ .rank = 2, .file = 1 },  .{ .rank = 2, .file = -1 },
    .{ .rank = -2, .file = 1 }, .{ .rank = -2, .file = -1 },
    .{ .rank = 1, .file = 2 },  .{ .rank = 1, .file = -2 },
    .{ .rank = -1, .file = 2 }, .{ .rank = -1, .file = -2 },
};

// Pawns are mean pieces they can move in two directions based on some conditions and then they get
// granted geenie whish to change into any piece other than the king when they reach their
// respective last rank, so you got to handle promotions as well. I'm a slave driver, I don't do
// promotions, only captures. (Insert Evil Laugh)
//
// Seriously who is recruiting these idiots that can only move forward, and only attack diagonally?
// Why are spatially challenged people soldiers??? (I remember hearing this joke from somewhere
// and I love it)

/// Direction a white pawn advances (toward higher rank).
pub const WHITE_PAWN_FORWARD: Direction = .north;

/// Direction a black pawn advances (toward lower rank).
pub const BLACK_PAWN_FORWARD: Direction = .south;

/// The two diagonals a white pawn attacks/captures on.
pub const WHITE_PAWN_CAPTURE_DIRECTIONS: [2]Direction = .{ .north_east, .north_west };

/// The two diagonals a black pawn attacks/captures on.
pub const BLACK_PAWN_CAPTURE_DIRECTIONS: [2]Direction = .{ .south_east, .south_west };

/// Given a direction and a position returns the first non-empty piece encounterd if any,
/// otherwise returns .empty.
/// Searchs in 8 directions with deltas give as +-1 or 0 for both rank files.
pub fn ray_find_piece(board: *const Board, start: Position, direction: Direction) Piece {
    // Get the delta for the direction and tick by one so we're not on the starting position.
    const delta = direction.deltas();

    // We need i8's because our rank and file's are 0-7 and if we go with u8 or some other
    // variant, the bounds check become a bit complicated since wrap arounds can happen.
    // With negatives we can directly check for rank/file < 0 and keep things simple.
    var rank: i8 = @as(i8, @intCast(start.rank)) + delta.rank;
    var file: i8 = @as(i8, @intCast(start.file)) + delta.file;

    while (rank >= 0 and rank <= 7 and file >= 0 and file <= 7) {
        // intCast since indexing requires a usize.
        const piece = board.board_state[@intCast(rank)][@intCast(file)];
        if (piece != .empty) {
            return piece;
        }

        rank += delta.rank;
        file += delta.file;
    }

    return .empty;
}

// I was first doing it inline with a lot of repetition. Don't ask me how long it took me to get to
// this function.
/// Walks a ray from `from` in `direction`, appending every legal move to `out`. Legal squares are:
/// empty squares along the ray, plus the first opposite-color piece encountered (as a capture).
/// Walking stops at board edge, on a same-color piece (exclusive), or after the capture.
/// Shared by bishops, rooks, and queens — the only difference across piece types is which
/// direction set they iterate. `from` must be on the board.
pub fn collect_ray_moves(
    board: *const Board,
    from: Position,
    direction: Direction,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const delta = direction.deltas();

    // i8 for the same reason ray_find_piece uses it: u3/u8 wrap on negatives, so bounds checks get
    // awkward. With i8 we just guard `< 0` and `> 7`.
    var rank: i8 = @as(i8, @intCast(from.rank)) + delta.rank;
    var file: i8 = @as(i8, @intCast(from.file)) + delta.file;

    while (rank >= 0 and rank <= 7 and file >= 0 and file <= 7) {
        const target_rank: u3 = @intCast(rank);
        const target_file: u3 = @intCast(file);
        const piece = board.board_state[target_rank][target_file];

        if (piece == .empty) {
            out.append_assume_capacity(.{
                .from = from,
                .to = .{ .rank = target_rank, .file = target_file },
            });
        } else {
            if (piece.color().? != turn) {
                out.append_assume_capacity(.{
                    .from = from,
                    .to = .{ .rank = target_rank, .file = target_file },
                });
            }
            break;
        }

        rank += delta.rank;
        file += delta.file;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_util = @import("test_util.zig");

test "collect_ray_moves east from a1: white rook on a1, black pawn on c1 → b1 + c1 capture" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_pawn, .{ .rank = 0, .file = 2 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    collect_ray_moves(&board, .{ .rank = 0, .file = 0 }, .east, .white, &out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqual(@as(u3, 1), out.slice()[0].to.file); // b1
    try testing.expectEqual(@as(u3, 2), out.slice()[1].to.file); // c1 (capture)
}

test "collect_ray_moves east from a1: friendly blocker on c1 → only b1" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 0, .file = 2 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    collect_ray_moves(&board, .{ .rank = 0, .file = 0 }, .east, .white, &out);

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u3, 1), out.slice()[0].to.file); // b1 only
}

test "collect_ray_moves east from h1 stops at edge without appending" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    collect_ray_moves(&board, .{ .rank = 0, .file = 7 }, .east, .white, &out);

    try testing.expectEqual(@as(usize, 0), out.len);
}

test "ray_find_piece east from a1 on starting board returns .white_knight" {
    var board: Board = undefined;
    board.init();

    const piece = ray_find_piece(&board, .{ .rank = 0, .file = 0 }, .east);
    try testing.expectEqual(Piece.white_knight, piece);
}

test "ray_find_piece north from e2 on starting board returns .black_pawn" {
    var board: Board = undefined;
    board.init();

    // e2 is the white pawn; scanning north from e2 walks empty ranks 3-6 and hits black pawn at e7.
    const piece = ray_find_piece(&board, .{ .rank = 1, .file = 4 }, .north);
    try testing.expectEqual(Piece.black_pawn, piece);
}
