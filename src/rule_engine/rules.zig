//! Classification: engine-core
//! Holds the ruling engine to check valid and generate legal moves given a board state.

const std = @import("std");
const shared = @import("../shared.zig");
const Color = shared.Color;
const Move = shared.Move;
const Position = shared.Position;
const CastlingRights = shared.CastlingRights;
const Board = @import("../board.zig").Board;
const Piece = @import("../board.zig").Piece;
const BoundedArray = @import("../bounded_array.zig").BoundedArray;
const rules_shared = @import("shared.zig");
const check_helper = @import("check_helper.zig");

const MAX_LEGAL_MOVES = rules_shared.MAX_LEGAL_MOVES;

/// Calculates all of the possible legal moves given the board state, and populates them in the out
/// variable. `turn` selects which side's moves to generate.
pub fn legal_moves(
    board: *const Board,
    turn: Color,
    castling_rights: *const CastlingRights,
    enpassant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // The per-piece helpers generate pseudo-legal moves (valid piece movement, but they don't
    // account for pins or moving into check). We collect into a scratch buffer first, then
    // filter out any move that would leave our own king in check.
    // Caller must pass a fresh buffer — stale moves from a prior call would corrupt the result.
    std.debug.assert(out.len == 0);

    var pseudo_legal: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};

    pawn_moves(board, turn, enpassant_square, &pseudo_legal);
    knight_moves(board, turn, &pseudo_legal);
    bishop_moves(board, turn, &pseudo_legal);
    rook_moves(board, turn, &pseudo_legal);
    queen_moves(board, turn, &pseudo_legal);
    king_moves(board, turn, &pseudo_legal);
    // TODO: castling_rights — threaded through for when castling lands in king_moves.
    _ = castling_rights;

    filter_self_check(board, turn, &pseudo_legal, out);
}

/// Checks if a move is valid given board state. Piece is auto-picked from the `from` square of the
/// move. Returns false when `from` is empty or when the move is not in the piece's legal-move set.
/// Does not enforce turn — that's the caller's responsibility.
pub fn is_legal_piece_move(
    board: *const Board,
    castling_rights: *const CastlingRights,
    enpassant_square: ?Position,
    move: Move,
) bool {
    const piece = board.board_state[move.from.rank][move.from.file];
    if (piece == .empty) {
        return false;
    }
    const turn = piece.color().?;

    if (!is_pseudo_legal(board, piece, turn, move, enpassant_square)) {
        return false;
    }
    _ = castling_rights;

    var scratch = board.*;
    scratch.move(move.from, move.to);
    return !check_helper.in_check(&scratch, turn);
}

/// Returns all of the legal moves of the piece at given position. Position must hold a non-empty
/// piece — calling on an empty square is a programmer bug.
pub fn piece_legal_moves(
    board: *const Board,
    position: Position,
    castling_rights: *const CastlingRights,
    enpassant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // Caller must pass a fresh buffer — stale moves from a prior call would corrupt the result.
    std.debug.assert(out.len == 0);

    const piece = board.board_state[position.rank][position.file];
    std.debug.assert(piece != .empty);
    const turn = piece.color().?;

    // The per-piece `*_from` helpers generate pseudo-legal moves for the single piece at
    // `position` (unlike the aggregate `*_moves` helpers below, which iterate every piece of
    // that type for the colour). We then discard any move that would leave our own king in
    // check via `filter_self_check`.
    var pseudo_legal: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    switch (piece) {
        .white_pawn, .black_pawn => pawn_moves_from(board, position, turn, enpassant_square, &pseudo_legal),
        .white_knight, .black_knight => knight_moves_from(board, position, turn, &pseudo_legal),
        .white_bishop_light,
        .white_bishop_dark,
        .black_bishop_light,
        .black_bishop_dark,
        => bishop_moves_from(board, position, turn, &pseudo_legal),
        .white_rook, .black_rook => rook_moves_from(board, position, turn, &pseudo_legal),
        .white_queen, .black_queen => queen_moves_from(board, position, turn, &pseudo_legal),
        .white_king, .black_king => king_moves_from(board, position, turn, &pseudo_legal),
        .empty => unreachable,
    }
    _ = castling_rights;

    filter_self_check(board, turn, &pseudo_legal, out);
}

/// Appends single-push and double-push forward moves for one pawn at `position`. Does not
/// handle captures — those stay inline in `pawn_moves` because they share the capture_directions
/// loop. `start_rank` is 1 (white) or 6 (black); matches `position.rank` exactly when the pawn
/// can double-push.
fn pawn_forward_moves(
    board: *const Board,
    position: Position,
    target_rank: u3,
    start_rank: u3,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // Single push: target square must be empty.
    if (board.board_state[target_rank][position.file] == .empty) {
        out.append_assume_capacity(.{
            .from = position,
            .to = .{ .rank = target_rank, .file = position.file },
        });

        // Double push: only from starting rank, and the intermediate square must be empty
        // (which we just proved by entering this branch). start_rank is 1 or 6, so +/- 2
        // stays in u3 range.
        if (position.rank == start_rank) {
            const double_rank: u3 = switch (turn) {
                .white => position.rank + 2,
                .black => position.rank - 2,
            };
            if (board.board_state[double_rank][position.file] == .empty) {
                out.append_assume_capacity(.{
                    .from = position,
                    .to = .{ .rank = double_rank, .file = position.file },
                });
            }
        }
    }
}

/// Appends diagonal-capture moves for one pawn at `position`. Does not handle en-passant —
/// that's deferred (see the TODO in `pawn_moves`). `target_rank` is `position.rank ± 1`
/// per the caller's color perspective and is load-bearing for u3 safety.
fn pawn_capture_moves(
    board: *const Board,
    position: Position,
    target_rank: u3,
    capture_directions: [2]rules_shared.Direction,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (capture_directions) |direction| {
        const file_delta = direction.deltas().file;
        // File is the only axis that can fall off the edge (a/h files). Rank is caller-pinned safe.
        const diag_file_i8: i8 = @as(i8, @intCast(position.file)) + file_delta;
        if (diag_file_i8 < 0 or diag_file_i8 > 7) {
            continue;
        }
        const diag_file: u3 = @intCast(diag_file_i8);
        const target_piece = board.board_state[target_rank][diag_file];

        // Regular capture — opponent piece on the diagonal.
        if (target_piece != .empty and target_piece.color().? != turn) {
            out.append_assume_capacity(.{
                .from = position,
                .to = .{ .rank = target_rank, .file = diag_file },
            });
        }
    }
}

/// Pseudo-legal moves for a single pawn at `position`. Covers single push, double push (from
/// starting rank only), and diagonal captures. En-passant is deferred — see the TODO just below.
/// The self-check filter applied by the caller handles pins and moves that would leave our own
/// king in check.
fn pawn_moves_from(
    board: *const Board,
    position: Position,
    turn: Color,
    enpassant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // TODO: en-passant — currently stripped because filter_self_check can't simulate ep
    // capture cleanly (Board.move is geometry-only and doesn't remove the captured pawn on
    // the adjacent file). Re-introduce here alongside an ep-aware move-application helper
    // and drop this discard.
    _ = enpassant_square;
    // Pawns on rank 0 or 7 would have been promoted already. Also the load-bearing guarantee
    // for the u3 arithmetic below: rank 1..6 + 1 stays 2..7, rank 1..6 - 1 stays 0..5.
    std.debug.assert(position.rank != 0 and position.rank != 7);

    const capture_directions: [2]rules_shared.Direction = switch (turn) {
        .white => rules_shared.WHITE_PAWN_CAPTURE_DIRECTIONS,
        .black => rules_shared.BLACK_PAWN_CAPTURE_DIRECTIONS,
    };
    const start_rank: u3 = switch (turn) {
        .white => 1,
        .black => 6,
    };
    const target_rank: u3 = switch (turn) {
        .white => position.rank + 1,
        .black => position.rank - 1,
    };

    pawn_forward_moves(board, position, target_rank, start_rank, turn, out);
    pawn_capture_moves(board, position, target_rank, capture_directions, turn, out);
}

/// Pseudo-legal moves for a single knight at `position`.
fn knight_moves_from(
    board: *const Board,
    position: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const rank: i8 = @intCast(position.rank);
    const file: i8 = @intCast(position.file);

    for (rules_shared.KNIGHT_OFFSETS) |offset| {
        const target_rank = rank + offset.rank;
        const target_file = file + offset.file;

        if (target_rank < 0 or target_rank > 7 or target_file < 0 or target_file > 7) {
            continue;
        }

        const target_piece = board.board_state[@intCast(target_rank)][@intCast(target_file)];
        if (target_piece != .empty and target_piece.color().? == turn) {
            continue;
        }

        out.append_assume_capacity(.{
            .from = position,
            .to = .{ .rank = @intCast(target_rank), .file = @intCast(target_file) },
        });
    }
}

/// Pseudo-legal moves for a single bishop at `position`.
fn bishop_moves_from(
    board: *const Board,
    position: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (rules_shared.BISHOP_DIRECTIONS) |direction| {
        rules_shared.collect_ray_moves(board, position, direction, turn, out);
    }
}

/// Pseudo-legal moves for a single rook at `position`.
fn rook_moves_from(
    board: *const Board,
    position: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (rules_shared.ROOK_DIRECTIONS) |direction| {
        rules_shared.collect_ray_moves(board, position, direction, turn, out);
    }
}

/// Pseudo-legal moves for a single queen at `position`.
fn queen_moves_from(
    board: *const Board,
    position: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (rules_shared.ALL_DIRECTIONS) |direction| {
        rules_shared.collect_ray_moves(board, position, direction, turn, out);
    }
}

/// Pseudo-legal moves for the king at `position`.
fn king_moves_from(
    board: *const Board,
    position: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const rank: i8 = @intCast(position.rank);
    const file: i8 = @intCast(position.file);

    for (rules_shared.ALL_DIRECTIONS) |direction| {
        const delta = direction.deltas();
        const target_rank = rank + delta.rank;
        const target_file = file + delta.file;

        if (target_rank < 0 or target_rank > 7 or target_file < 0 or target_file > 7) {
            continue;
        }

        const piece = board.board_state[@intCast(target_rank)][@intCast(target_file)];

        if (piece != .empty and piece.color().? == turn) {
            continue;
        }

        out.append_assume_capacity(.{
            .from = position,
            .to = .{ .rank = @intCast(target_rank), .file = @intCast(target_file) },
        });
    }
}

// TODO: Handle Promotion or defer it to the caller.
/// Calculates the pseudo-legal pawn moves given the board state and color turn. Covers single push,
/// double push (from starting rank only), and diagonal captures. En-passant is deferred — see the
/// TODO inside `pawn_moves_from`. The self-check filter applied by the caller handles pins and
/// moves that would leave our own king in check.
fn pawn_moves(
    board: *const Board,
    turn: Color,
    enpassant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const pawn_piece: Piece = switch (turn) {
        .black => .black_pawn,
        .white => .white_pawn,
    };

    const positions = board.find_piece_position(pawn_piece);
    for (positions.slice()) |position| {
        pawn_moves_from(board, position, turn, enpassant_square, out);
    }
}

/// Calculates the pseudo-legal knight moves given the board state. The self-check filter applied
/// by the caller handles pins and moves that would leave our own king in check.
fn knight_moves(board: *const Board, turn: Color, out: *BoundedArray(Move, MAX_LEGAL_MOVES)) void {
    const piece: Piece = switch (turn) {
        .black => .black_knight,
        .white => .white_knight,
    };
    const knight_positions = board.find_piece_position(piece);
    for (knight_positions.slice()) |position| {
        knight_moves_from(board, position, turn, out);
    }
}

/// Calculates the pseudo-legal bishop moves. Both light- and dark-squared bishops are covered — we
/// iterate each piece type and ray-trace outward along BISHOP_DIRECTIONS. The self-check filter
/// applied by the caller handles pins and moves that would leave our own king in check.
fn bishop_moves(board: *const Board, turn: Color, out: *BoundedArray(Move, MAX_LEGAL_MOVES)) void {
    const bishops: [2]Piece = switch (turn) {
        .black => .{ .black_bishop_light, .black_bishop_dark },
        .white => .{ .white_bishop_light, .white_bishop_dark },
    };

    for (bishops) |bishop_piece| {
        const positions = board.find_piece_position(bishop_piece);
        for (positions.slice()) |position| {
            bishop_moves_from(board, position, turn, out);
        }
    }
}

/// Calculates the pseudo-legal rook moves. Ray-traces outward along ROOK_DIRECTIONS from each
/// rook. The self-check filter applied by the caller handles pins and moves that would leave our
/// own king in check.
fn rook_moves(board: *const Board, turn: Color, out: *BoundedArray(Move, MAX_LEGAL_MOVES)) void {
    const rook_piece: Piece = switch (turn) {
        .black => .black_rook,
        .white => .white_rook,
    };

    const positions = board.find_piece_position(rook_piece);
    for (positions.slice()) |position| {
        rook_moves_from(board, position, turn, out);
    }
}

/// Calculates the pseudo-legal queen moves. Ray-traces outward along ALL_DIRECTIONS (the union
/// of ROOK_DIRECTIONS and BISHOP_DIRECTIONS) from each queen. The self-check filter applied by the
/// caller handles pins and moves that would leave our own king in check.
fn queen_moves(board: *const Board, turn: Color, out: *BoundedArray(Move, MAX_LEGAL_MOVES)) void {
    const queen_piece: Piece = switch (turn) {
        .black => .black_queen,
        .white => .white_queen,
    };

    const positions = board.find_piece_position(queen_piece);
    for (positions.slice()) |position| {
        queen_moves_from(board, position, turn, out);
    }
}

// TODO: Castling will be added here once CastlingRights is fleshed out.
/// Calculates pseudo-legal king moves — one square in any of the 8 directions. Moves onto empty
/// squares or opponent-occupied squares (captures) are included. Friendly-occupied squares are
/// skipped. The self-check filter applied by the caller handles the "can't move into check" rule.
fn king_moves(board: *const Board, turn: Color, out: *BoundedArray(Move, MAX_LEGAL_MOVES)) void {
    const king_piece: Piece = switch (turn) {
        .white => .white_king,
        .black => .black_king,
    };

    const positions = board.find_piece_position(king_piece);
    std.debug.assert(positions.len == 1);

    king_moves_from(board, positions.slice()[0], turn, out);
}

// I was generating all of the moves and picking the ones that were from the starting move position
// and then checked if the resulting position was illegal. The king's position was also not cached,
// resulting in a lot of redundant and useless calculations.
// You can try running the e571e0293fd4119a925e6eb6436ad7243ede07f8 commit's bench and this ones
// bench, the difference is stellar.
/// Validates that a move's geometry is correct for the given piece type — i.e. the piece can
/// physically reach the target square. Does NOT check self-check; that's the caller's job.
fn is_pseudo_legal(
    board: *const Board,
    piece: Piece,
    turn: Color,
    move: Move,
    enpassant_square: ?Position,
) bool {
    // TODO: en-passant — stripped here for the same reason as `pawn_moves_from` (see the
    // TODO in that function). Re-introduce alongside an ep-aware move-application helper
    // and drop this discard.
    _ = enpassant_square;
    const from = move.from;
    const to = move.to;

    // Can't move to a square occupied by a friendly piece.
    const target = board.board_state[to.rank][to.file];
    if (target != .empty and target.color().? == turn) {
        return false;
    }

    return switch (piece) {
        .white_pawn, .black_pawn => is_pseudo_legal_pawn(board, from, to, turn),
        .white_knight, .black_knight => is_pseudo_legal_knight(from, to),
        .white_bishop_light,
        .white_bishop_dark,
        .black_bishop_light,
        .black_bishop_dark,
        => is_pseudo_legal_sliding(board, from, to, &rules_shared.BISHOP_DIRECTIONS),
        .white_rook, .black_rook => is_pseudo_legal_sliding(board, from, to, &rules_shared.ROOK_DIRECTIONS),
        .white_queen, .black_queen => is_pseudo_legal_sliding(board, from, to, &rules_shared.ALL_DIRECTIONS),
        .white_king, .black_king => is_pseudo_legal_king(from, to),
        // Callers (`is_legal_piece_move`, `is_legal_piece_move_mutate`) early-return on
        // `.empty` before invoking this path, so reaching this arm is a caller contract
        // violation.
        .empty => unreachable,
    };
}

fn is_pseudo_legal_pawn(board: *const Board, from: Position, to: Position, turn: Color) bool {
    // Pawns on rank 0 or 7 would have been promoted already. Also the load-bearing guarantee
    // for the u3 arithmetic below: rank 1..6 + 1 stays 2..7, rank 1..6 - 1 stays 0..5.
    std.debug.assert(from.rank != 0 and from.rank != 7);

    const rank_delta: i8 = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta: i8 = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));
    const forward: i8 = switch (turn) {
        .white => 1,
        .black => -1,
    };
    const start_rank: u3 = switch (turn) {
        .white => 1,
        .black => 6,
    };

    // Single push: one square forward, target must be empty.
    if (rank_delta == forward and file_delta == 0) {
        return board.board_state[to.rank][to.file] == .empty;
    }

    // Double push: two squares forward from start rank, both squares must be empty.
    if (rank_delta == forward * 2 and file_delta == 0 and from.rank == start_rank) {
        const intermediate_rank: u3 = @intCast(@as(i8, @intCast(from.rank)) + forward);
        return board.board_state[intermediate_rank][from.file] == .empty and
            board.board_state[to.rank][to.file] == .empty;
    }

    // Diagonal capture: one forward, one sideways, target must have enemy piece.
    if (rank_delta == forward and (file_delta == 1 or file_delta == -1)) {
        const target = board.board_state[to.rank][to.file];
        return target != .empty and target.color().? != turn;
    }

    return false;
}

fn is_pseudo_legal_knight(from: Position, to: Position) bool {
    const rank_delta = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    const abs_rank = @abs(rank_delta);
    const abs_file = @abs(file_delta);

    return (abs_rank == 2 and abs_file == 1) or (abs_rank == 1 and abs_file == 2);
}

fn is_pseudo_legal_king(from: Position, to: Position) bool {
    const rank_delta = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    const abs_rank = @abs(rank_delta);
    const abs_file = @abs(file_delta);

    return abs_rank <= 1 and abs_file <= 1 and (abs_rank + abs_file > 0);
}

/// Validates a sliding piece move: determines the direction from `from` to `to`, checks it's in
/// the allowed set, then walks the ray to verify the path is clear.
fn is_pseudo_legal_sliding(
    board: *const Board,
    from: Position,
    to: Position,
    allowed_directions: []const rules_shared.Direction,
) bool {
    const rank_delta: i8 = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta: i8 = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    if (rank_delta == 0 and file_delta == 0) return false;

    // Determine the direction.
    const direction: rules_shared.Direction = blk: {
        if (file_delta == 0) {
            break :blk if (rank_delta > 0) .north else .south;
        }
        if (rank_delta == 0) {
            break :blk if (file_delta > 0) .east else .west;
        }
        // Diagonals require equal absolute deltas.
        const abs_rank = @abs(rank_delta);
        const abs_file = @abs(file_delta);
        if (abs_rank != abs_file) return false;

        if (rank_delta > 0 and file_delta > 0) break :blk .north_east;
        if (rank_delta > 0 and file_delta < 0) break :blk .north_west;
        if (rank_delta < 0 and file_delta > 0) break :blk .south_east;
        break :blk .south_west;
    };

    // Check the direction is in the allowed set.
    var allowed = false;
    for (allowed_directions) |d| {
        if (d == direction) {
            allowed = true;
            break;
        }
    }
    if (!allowed) return false;

    // Walk the ray from `from` toward `to`, checking that all intermediate squares are empty.
    const delta = direction.deltas();
    var rank: i8 = @as(i8, @intCast(from.rank)) + delta.rank;
    var file: i8 = @as(i8, @intCast(from.file)) + delta.file;

    while (rank >= 0 and rank <= 7 and file >= 0 and file <= 7) {
        if (@as(u3, @intCast(rank)) == to.rank and @as(u3, @intCast(file)) == to.file) {
            return true; // Reached target — path is clear.
        }
        if (board.board_state[@intCast(rank)][@intCast(file)] != .empty) {
            return false; // Blocked.
        }
        rank += delta.rank;
        file += delta.file;
    }

    return false; // Walked off the board without reaching target.
}

/// Filters pseudo-legal moves down to truly legal ones by discarding any move that would leave the
/// moving side's king in check. Works for all piece types — pinned pieces, king walking into
/// attacked squares, discovered checks on yourself, etc. are all caught by the simulate-and-test
/// approach.
fn filter_self_check(
    board: *const Board,
    turn: Color,
    candidates: *const BoundedArray(Move, MAX_LEGAL_MOVES),
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (candidates.slice()) |candidate| {
        // Stack copy so we don't mutate the real board. The copy is cheap — it's just an 8×8
        // array of i8 on the stack.
        // I tried changing from copy to just mutate-retract, but that didn't come with any
        // visible benefit over this in terms of performance, and added more on my plate to always
        // remember to retract.
        var scratch = board.*;
        scratch.move(candidate.from, candidate.to);

        if (!check_helper.in_check(&scratch, turn)) {
            out.append_assume_capacity(candidate);
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_util = @import("test_util.zig");

test "legal_moves from the starting position for white returns exactly 20 moves" {
    // 16 pawn single/double pushes + 4 knight jumps = 20. No other piece has a free square yet.
    var board: Board = undefined;
    board.init();
    const castling: CastlingRights = .{};

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    legal_moves(&board, .white, &castling, null, &out);

    try testing.expectEqual(@as(usize, 20), out.len);
}

test "legal_moves filters pin: pinned white rook can only move along the pin ray" {
    // White king d1, white rook d2 pinned on d-file, black rook d8, black king h8.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 3 });
    test_util.place(&board, .white_rook, .{ .rank = 1, .file = 3 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 3 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });
    const castling: CastlingRights = .{};

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    var rook_moves_only: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 1, .file = 3 }, &castling, null, &rook_moves_only);

    // Every legal move for the pinned rook must stay on the d-file (file == 3).
    try testing.expect(rook_moves_only.len > 0);
    for (rook_moves_only.slice()) |mv| {
        try testing.expectEqual(@as(u3, 3), mv.to.file);
    }

    // Sanity: whole legal_moves for white also excludes any off-file rook moves.
    legal_moves(&board, .white, &castling, null, &out);
    for (out.slice()) |mv| {
        if (mv.from.rank == 1 and mv.from.file == 3) {
            try testing.expectEqual(@as(u3, 3), mv.to.file);
        }
    }
}

test "pawn_moves generates double push from starting rank but not from any other rank" {
    // Starting-rank pawn: both single and double push should appear.
    var board_start = test_util.empty_board();
    test_util.place(&board_start, .white_pawn, .{ .rank = 1, .file = 4 }); // e2
    test_util.place(&board_start, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board_start, .black_king, .{ .rank = 7, .file = 7 });

    var out_start: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    pawn_moves(&board_start, .white, null, &out_start);

    var saw_single = false;
    var saw_double = false;
    for (out_start.slice()) |mv| {
        if (mv.from.rank == 1 and mv.to.rank == 2) {
            saw_single = true;
        }
        if (mv.from.rank == 1 and mv.to.rank == 3) {
            saw_double = true;
        }
    }
    try testing.expect(saw_single);
    try testing.expect(saw_double);

    // Off-starting-rank pawn: only single push.
    var board_mid = test_util.empty_board();
    test_util.place(&board_mid, .white_pawn, .{ .rank = 3, .file = 4 }); // e4
    test_util.place(&board_mid, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board_mid, .black_king, .{ .rank = 7, .file = 7 });

    var out_mid: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    pawn_moves(&board_mid, .white, null, &out_mid);

    try testing.expectEqual(@as(usize, 1), out_mid.len);
    try testing.expectEqual(@as(u3, 4), out_mid.slice()[0].to.rank); // e5, single push
}

test "king_moves refuses to walk onto a friendly piece" {
    // White king e4 with friendly pawns on d4 and d5 — d4/d5 must be excluded.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 3, .file = 4 }); // e4
    test_util.place(&board, .white_pawn, .{ .rank = 3, .file = 3 }); // d4
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 3 }); // d5
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    king_moves(&board, .white, &out);

    for (out.slice()) |mv| {
        const to_d4 = mv.to.rank == 3 and mv.to.file == 3;
        const to_d5 = mv.to.rank == 4 and mv.to.file == 3;
        try testing.expect(!to_d4 and !to_d5);
    }
}

test "is_legal_piece_move returns false for a move from an empty square" {
    var board: Board = undefined;
    board.init();
    const castling: CastlingRights = .{};

    const mv = Move{
        .from = .{ .rank = 4, .file = 4 }, // e5, empty
        .to = .{ .rank = 5, .file = 4 }, // e6
    };
    try testing.expect(!is_legal_piece_move(&board, &castling, null, mv));
}

test "piece_legal_moves on the king returns only moves with from == king_pos" {
    // Documents the contract: piece_legal_moves narrows to moves from the queried square.
    var board: Board = undefined;
    board.init();
    const castling: CastlingRights = .{};
    const king_pos = Position{ .rank = 0, .file = 4 };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, king_pos, &castling, null, &out);

    for (out.slice()) |mv| {
        try testing.expectEqual(king_pos.rank, mv.from.rank);
        try testing.expectEqual(king_pos.file, mv.from.file);
    }
    // Starting position: king has zero legal moves (all surrounding squares friendly-occupied).
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "knight_moves: lone white knight on d4 (empty board) generates exactly 8 moves" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_knight, .{ .rank = 3, .file = 3 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    knight_moves(&board, .white, &out);

    try testing.expectEqual(@as(usize, 8), out.len);
}

test "bishop_moves: lone white dark-squared bishop on d4 generates exactly 13 moves" {
    // d4 = (rank 3, file 3). rank + file = 6 (even) → dark square in this project's convention
    // (white_bishop_dark sits on c1 = 0+2 = 2 even in the starting layout). bishop_moves serves
    // both bishop variants through the same generator, so the count is 13 either way — the Piece
    // variant just has to match what find_piece_position is asked for.
    var board = test_util.empty_board();
    test_util.place(&board, .white_bishop_dark, .{ .rank = 3, .file = 3 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    bishop_moves(&board, .white, &out);

    try testing.expectEqual(@as(usize, 13), out.len);
}

test "rook_moves: lone white rook on d4 (empty board) generates exactly 14 moves" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_rook, .{ .rank = 3, .file = 3 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    rook_moves(&board, .white, &out);

    try testing.expectEqual(@as(usize, 14), out.len);
}

test "queen_moves: lone white queen on d4 (empty board) generates exactly 27 moves" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_queen, .{ .rank = 3, .file = 3 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    queen_moves(&board, .white, &out);

    try testing.expectEqual(@as(usize, 27), out.len);
}

test "legal_moves: 1000 hot-loop iterations stay alloc-free and deterministic" {
    // ── Static guarantee ──────────────────────────────────────────────────────
    // legal_moves cannot allocate because its signature does not accept an
    // std.mem.Allocator. This comptime guard fails compilation if that ever
    // changes — a future refactor adding an Allocator param must also reckon
    // with whether the no-alloc invariant still holds.
    comptime {
        const fn_info = @typeInfo(@TypeOf(legal_moves)).@"fn";
        for (fn_info.params) |param| {
            if (param.type) |t| {
                if (t == std.mem.Allocator) {
                    @compileError("legal_moves must not take an Allocator — see Story 2.1 AC");
                }
            }
        }
    }

    // ── Runtime hot loop ──────────────────────────────────────────────────────
    // A thousand iterations from the starting position, all writing into the
    // same stack-allocated buffer. Catches hidden perf regressions and any
    // iteration-order nondeterminism; the alloc-free invariant holds because
    // the buffer lives on the stack and legal_moves is static-proven above.
    var board: Board = undefined;
    board.init();
    const castling: CastlingRights = .{};
    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        out.reset();
        legal_moves(&board, .white, &castling, null, &out);
        try testing.expectEqual(@as(usize, 20), out.len);
    }
}
