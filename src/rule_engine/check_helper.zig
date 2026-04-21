//! Classification: engine-core
//! Holds the logic for everything around checks.

const std = @import("std");
const shared = @import("../shared.zig");
const Color = shared.Color;
const Position = shared.Position;
const Board = @import("../board.zig").Board;
const Piece = @import("../board.zig").Piece;
const rules_shared = @import("shared.zig");

/// Verifies whether the king of the player/turn in question is in check or not. Returns bool value,
/// true if the king is in check, false otherwise.
pub fn in_check(board: *const Board, turn: Color) bool {
    const king_position = board.find_king_position(turn);

    // The different ways the king can be under check:
    //   1. Direct line of sight of a sliding piece (rook, bishop, or queen) along any of the 8
    //      directions — rook-like (rank/file) and bishop-like (diagonal) merged into one scan.
    //   2. On the diagonal attack sight of a pawn.
    //   3. A knight, on any of the L positions. (I know knights are a wonder on the board, heh)
    //   4. Adjacent enemy king. Two kings can never legally sit next to each other, so this
    //      only fires while probing hypothetical king moves — but it's load-bearing for
    //      `preview_move`'s self-check filter to reject walking into the enemy king's square.

    // Checks 1 and 2 are merged into a single 8-direction ray scan. Each ray finds the first
    // piece, then the direction tells us whether rook-like or bishop-like attackers apply.
    // Queens threaten along both, so they match in every direction.

    if (is_checked_by_sliding_piece(board, king_position, turn)) {
        return true;
    }

    if (is_checked_by_pawn(board, king_position, turn)) {
        return true;
    }

    if (is_checked_by_knight(board, king_position, turn)) {
        return true;
    }

    return is_checked_by_adjacent_king(board, king_position, turn);
}

/// Returns true if the king is in the line of sight of an opponent sliding piece (rook, bishop, or
/// queen) along any of the 8 directions. Merges the old rook/queen and bishop/queen checks into a
/// single pass — one `ray_find_piece` per direction, piece type matched against the ray's axis.
fn is_checked_by_sliding_piece(board: *const Board, king_position: Position, turn: Color) bool {
    const expected_king: Piece = if (turn == .white) .white_king else .black_king;
    std.debug.assert(board.board_state[king_position.rank][king_position.file] == expected_king);

    for (rules_shared.ALL_DIRECTIONS) |direction| {
        const piece = rules_shared.ray_find_piece(board, king_position, direction);

        if (piece == .empty or piece.color() == turn) {
            continue;
        }

        const is_diagonal = switch (direction) {
            .north_east, .north_west, .south_east, .south_west => true,
            else => false,
        };

        switch (piece) {
            .white_queen, .black_queen => return true,
            .white_rook, .black_rook => {
                if (!is_diagonal) return true;
            },
            .white_bishop_light,
            .white_bishop_dark,
            .black_bishop_light,
            .black_bishop_dark,
            => {
                if (is_diagonal) return true;
            },
            else => {},
        }
    }

    return false;
}

/// Returns true if an opponent pawn is on a diagonal attack square adjacent to the king.
fn is_checked_by_pawn(board: *const Board, king_position: Position, turn: Color) bool {
    const expected_king: Piece = if (turn == .white) .white_king else .black_king;
    // Caller contract: king_position must actually hold the king of the given turn color.
    std.debug.assert(board.board_state[king_position.rank][king_position.file] == expected_king);

    // If the king sits on its forward edge (rank 7 for white, rank 0 for black), there's no
    // rank where an attacking pawn could stand — bail early so the u3 arithmetic below stays safe.
    switch (turn) {
        .white => {
            if (king_position.rank == 7) {
                return false;
            }
        },
        .black => {
            if (king_position.rank == 0) {
                return false;
            }
        },
    }

    // The squares a pawn could attack me from are exactly the squares *my* own pawn captures
    // onto — the relationship is symmetric through the stationary square. So for a white king
    // we look at WHITE_PAWN_CAPTURE_DIRECTIONS (the two north diagonals) and check for a black
    // pawn there; mirror for black. Rank is pinned by the edge-check above; file still needs
    // a bounds guard since both diagonals use file ± 1.
    const attacker_rank: u3 = switch (turn) {
        .white => king_position.rank + 1,
        .black => king_position.rank - 1,
    };
    const enemy_pawn: Piece = switch (turn) {
        .white => .black_pawn,
        .black => .white_pawn,
    };
    const pawn_threat_directions: [2]rules_shared.Direction = switch (turn) {
        .white => rules_shared.WHITE_PAWN_CAPTURE_DIRECTIONS,
        .black => rules_shared.BLACK_PAWN_CAPTURE_DIRECTIONS,
    };

    for (pawn_threat_directions) |direction| {
        const file_delta = direction.deltas().file;
        const f_i8: i8 = @as(i8, @intCast(king_position.file)) + file_delta;

        if (f_i8 < 0 or f_i8 > 7) {
            continue;
        }

        if (board.board_state[attacker_rank][@intCast(f_i8)] == enemy_pawn) {
            return true;
        }
    }

    return false;
}

/// Returns true if the opponent king stands on any of the 8 squares adjacent to ours. A legal
/// chess position never has the two kings touching, but `preview_move`'s self-check simulates a
/// king move before calling `in_check`, so this guard is what actually forbids `Ke4` when the
/// enemy king sits on `e5`.
fn is_checked_by_adjacent_king(board: *const Board, king_position: Position, turn: Color) bool {
    const expected_king: Piece = if (turn == .white) .white_king else .black_king;
    std.debug.assert(board.board_state[king_position.rank][king_position.file] == expected_king);

    const enemy_king: Piece = if (turn == .white) .black_king else .white_king;
    const rank: i8 = @intCast(king_position.rank);
    const file: i8 = @intCast(king_position.file);

    for (rules_shared.ALL_DIRECTIONS) |direction| {
        const delta = direction.deltas();
        const target_rank = rank + delta.rank;
        const target_file = file + delta.file;

        if (target_rank < 0 or target_rank > 7 or target_file < 0 or target_file > 7) {
            continue;
        }

        if (board.board_state[@intCast(target_rank)][@intCast(target_file)] == enemy_king) {
            return true;
        }
    }

    return false;
}

/// Returns true if an opponent knight occupies any of the eight L-shaped offsets from the king.
fn is_checked_by_knight(board: *const Board, king_position: Position, turn: Color) bool {
    const expected_king: Piece = if (turn == .white) .white_king else .black_king;
    std.debug.assert(board.board_state[king_position.rank][king_position.file] == expected_king);

    const rank: i8 = @intCast(king_position.rank);
    const file: i8 = @intCast(king_position.file);

    for (rules_shared.KNIGHT_OFFSETS) |offset| {
        const target_rank = rank + offset.rank;
        const target_file = file + offset.file;

        if (target_rank < 0 or target_rank > 7 or target_file < 0 or target_file > 7) {
            continue;
        }

        const piece = board.board_state[@intCast(target_rank)][@intCast(target_file)];

        if (piece != .empty and piece.color() != turn) {
            switch (piece) {
                .white_knight, .black_knight => return true,
                else => {},
            }
        }
    }

    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_util = @import("test_util.zig");

test "in_check returns false on the starting position for white" {
    var board: Board = undefined;
    board.init();
    try testing.expect(!in_check(&board, .white));
}

test "in_check: black rook stares down white king's file with clear line" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 4 });
    try testing.expect(in_check(&board, .white));
}

test "in_check: black bishop pins white king diagonally" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_bishop_dark, .{ .rank = 4, .file = 0 }); // a5, diagonal to e1
    try testing.expect(in_check(&board, .white));
}

test "in_check: black queen attacks via rook-like line" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_queen, .{ .rank = 7, .file = 4 }); // e8 -> e1
    try testing.expect(in_check(&board, .white));
}

test "in_check: black queen attacks via bishop-like line" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_queen, .{ .rank = 3, .file = 7 }); // h4 -> e1 via diagonal
    try testing.expect(in_check(&board, .white));
}

test "in_check: black pawn on capture diagonal of white king" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_pawn, .{ .rank = 1, .file = 3 }); // d2, captures to e1
    try testing.expect(in_check(&board, .white));
}

test "in_check: black knight on L-offset of white king" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_knight, .{ .rank = 2, .file = 5 }); // f3 is an L from e1
    try testing.expect(in_check(&board, .white));
}

test "in_check: friendly piece blocks the line of sight" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_pawn, .{ .rank = 1, .file = 4 }); // e2 blocks
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 4 }); // e8
    try testing.expect(!in_check(&board, .white));
}

test "in_check: white king on edge file a1 with no attacker returns false" {
    // Edge-file guard: ensures the pawn-check's file ± 1 doesn't falsely trigger at the board edge.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });
    try testing.expect(!in_check(&board, .white));
}

test "in_check: enemy king on an adjacent square counts as check (both directions)" {
    // Two kings can never legally sit next to each other; this guard lets the legality path
    // reject a king move that would put the two in contact.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 3, .file = 4 }); // e4
    test_util.place(&board, .black_king, .{ .rank = 4, .file = 4 }); // e5
    try testing.expect(in_check(&board, .white));
    try testing.expect(in_check(&board, .black));
}
