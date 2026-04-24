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
const Direction = rules_shared.Direction;

const MAX_LEGAL_MOVES = rules_shared.MAX_LEGAL_MOVES;

pub const CastlingSide = enum {
    king_side,
    queen_side,
};

// Directly encoding these as constants to reduce runtime calculations. These are always the same
// irrespective of game so it makes sense to have them as comptime constants.
/// `between_files` are the files between the king's home and the rook's home that must be empty.
/// `king_path_files` are the files the king passes over (and lands on) that must be unattacked —
/// a subset of `between_files` on queen-side (the b-file must be empty but the king never stands
/// there). The starting square is attack-checked once up-front by `pseudo_legal_king`, not here.
const CastlingPlan = struct {
    rank: u3,
    rook_from_file: u3,
    rook_to_file: u3,
    between_files: []const u3,
    king_path_files: []const u3,
    side: CastlingSide,
};

const WHITE_KING_SIDE_PLAN: CastlingPlan = .{
    .rank = 0,
    .rook_from_file = 7,
    .rook_to_file = 5,
    .between_files = &.{ 5, 6 },
    .king_path_files = &.{ 5, 6 },
    .side = .king_side,
};

const WHITE_QUEEN_SIDE_PLAN: CastlingPlan = .{
    .rank = 0,
    .rook_from_file = 0,
    .rook_to_file = 3,
    .between_files = &.{ 1, 2, 3 },
    .king_path_files = &.{ 2, 3 },
    .side = .queen_side,
};

const BLACK_KING_SIDE_PLAN: CastlingPlan = .{
    .rank = 7,
    .rook_from_file = 7,
    .rook_to_file = 5,
    .between_files = &.{ 5, 6 },
    .king_path_files = &.{ 5, 6 },
    .side = .king_side,
};

const BLACK_QUEEN_SIDE_PLAN: CastlingPlan = .{
    .rank = 7,
    .rook_from_file = 0,
    .rook_to_file = 3,
    .between_files = &.{ 1, 2, 3 },
    .king_path_files = &.{ 2, 3 },
    .side = .queen_side,
};

/// Enum holding the different scenarios that a move can result in.
pub const MoveEffect = union(enum) {
    /// No captures occurred, the piece moved from position a to b.
    move_only,

    /// Pawn moved two squares forward. Caller must set the en-passant target square for the
    /// next ply: the square the pawn *passed over* (one rank behind its landing square from
    /// the mover's perspective).
    pawn_double_push,

    /// A capture occurred at the target position, i.e. `move.to`
    capture: Piece,

    /// En passant capture. The capture occurs at the capture at position.
    en_passant: struct { captured_pawn_at: Position },

    /// Castling. Player moves the king, the rook move is sent back as the move effect.
    castling: struct { side: CastlingSide, rook_from: Position, rook_to: Position },

    /// Pawn reached the last rank and is up for promotion.
    promotion: struct { capture: ?Piece },
};

/// Checks if the player of the given color is in a stalemate: not in check, and no legal moves.
pub fn is_stalemate(
    board: *const Board,
    player_color: Color,
    castling_rights: CastlingRights,
    en_passant_square: ?Position,
) bool {
    if (check_helper.in_check(board, player_color)) {
        return false;
    }
    return !has_any_legal_move(board, player_color, castling_rights, en_passant_square);
}

/// Checks if the player of the given color is checkmated: in check, and no legal moves.
pub fn is_checkmate(
    board: *const Board,
    player_color: Color,
    castling_rights: CastlingRights,
    en_passant_square: ?Position,
) bool {
    if (!check_helper.in_check(board, player_color)) {
        return false;
    }
    return !has_any_legal_move(board, player_color, castling_rights, en_passant_square);
}

/// Returns true as soon as any legal move exists for `player_color`. Walks every square and for
/// each piece belonging to `player_color` checks if that piece has any legal moves.
fn has_any_legal_move(
    board: *const Board,
    player_color: Color,
    castling_rights: CastlingRights,
    en_passant_square: ?Position,
) bool {
    // Holds the legal moves after the self-check filter strips the illegal ones. The
    // intermediate pseudo-legal buffer is owned by `piece_legal_moves` itself — bench A/B
    // showed that hoisting it out here saved nothing (see tmp/zig-review-local-mate-castling/
    // bench_AB_comparison.md) and forced an extra parameter on every caller.
    var legal: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};

    for (0..8) |rank| {
        for (0..8) |file| {
            const from: Position = .{ .rank = @intCast(rank), .file = @intCast(file) };
            const piece = board.board_state[from.rank][from.file];
            if (piece == .empty or piece.color().? != player_color) {
                continue;
            }

            legal.reset();
            piece_legal_moves(board, from, castling_rights, en_passant_square, &legal);
            if (legal.len > 0) {
                return true;
            }
        }
    }
    return false;
}

// I was generating all of the moves and picking the ones that were from the starting move position
// and then checked if the resulting position was illegal. The king's position was also not cached,
// resulting in a lot of redundant and useless calculations.
// You can try running the e571e0293fd4119a925e6eb6436ad7243ede07f8 commit's bench and this ones
// bench, the difference is stellar.
/// Validates that a move is fully legal for the piece sitting at `move.from` — geometry is
/// correct for the piece, the path is clear, the target isn't friendly, and the mover's king
/// isn't left in check after applying the move — then returns the side-effect as MoveEffect
/// (quiet, capture, promotion, en-passant, castling, double-push). The mover piece is read
/// from the board rather than supplied by the caller: there's only one correct answer, so
/// taking it as a parameter would just create a second place for caller data to drift. `turn`
/// stays caller-supplied because it represents *whose move this is* — moving an opponent's
/// piece is a real violation this function catches.
pub fn preview_move(
    board: *const Board,
    turn: Color,
    move: Move,
    castling_rights: CastlingRights,
    en_passant_square: ?Position,
) !MoveEffect {
    const from = move.from;
    const to = move.to;

    const piece = board.board_state[from.rank][from.file];
    if (piece == .empty) {
        return error.InvalidMove;
    }
    // Can't move an opponent's piece on your turn.
    if (piece.color().? != turn) {
        return error.InvalidMove;
    }

    const target = board.board_state[to.rank][to.file];
    if (target != .empty) {
        // Can't move to a square occupied by a friendly piece.
        if (target.color().? == turn) {
            return error.InvalidMove;
        }
        // Kings are never captured — checkmate ends the game first. Reject any move that
        // targets the opposing king so hand-crafted positions (king left en-prise) can't
        // coax a "legal" king-capture out of the engine.
        if (target == .white_king or target == .black_king) {
            return error.InvalidMove;
        }
    }

    const effect: MoveEffect = try switch (piece) {
        .white_pawn, .black_pawn => pseudo_legal_pawn(board, from, to, turn, en_passant_square),
        .white_knight, .black_knight => pseudo_legal_knight(board, from, to, turn),
        .white_bishop_light,
        .white_bishop_dark,
        .black_bishop_light,
        .black_bishop_dark,
        => pseudo_legal_sliding(board, from, to, turn, &rules_shared.BISHOP_DIRECTIONS),
        .white_rook, .black_rook => pseudo_legal_sliding(board, from, to, turn, &rules_shared.ROOK_DIRECTIONS),
        .white_queen, .black_queen => pseudo_legal_sliding(board, from, to, turn, &rules_shared.ALL_DIRECTIONS),
        .white_king, .black_king => pseudo_legal_king(board, from, to, turn, castling_rights),
        // Guarded by the early `piece == .empty` return above.
        .empty => unreachable,
    };

    // Self-check filter: simulate the effect on a scratch board and reject if the mover's
    // king ends up attacked. Covers pins, discovered checks, and kings walking into
    // attacked squares in a single pass.
    var scratch = board.*;
    apply_effect(&scratch, move, effect);
    if (check_helper.in_check(&scratch, turn)) {
        return error.InvalidMove;
    }

    return effect;
}

fn pseudo_legal_pawn(
    board: *const Board,
    from: Position,
    to: Position,
    turn: Color,
    en_passant_square: ?Position,
) !MoveEffect {
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
    if (rank_delta == forward and file_delta == 0 and board.board_state[to.rank][to.file] == .empty) {
        // Back-rank push is a quiet promotion. Caller-supplied promotion piece lives on
        // GameCommand.move.promotion — the rule engine only reports that it's a promotion.
        if (to.rank == 0 or to.rank == 7) {
            return .{ .promotion = .{ .capture = null } };
        }
        return .move_only;
    }

    // Double push: two squares forward from start rank, both squares must be empty.
    if (rank_delta == forward * 2 and file_delta == 0 and from.rank == start_rank) {
        const intermediate_rank: u3 = @intCast(@as(i8, @intCast(from.rank)) + forward);
        if (board.board_state[intermediate_rank][from.file] == .empty and
            board.board_state[to.rank][to.file] == .empty)
        {
            return .pawn_double_push;
        }
    }

    // Diagonal capture: one forward, one sideways. Target must be an enemy piece, OR the
    // target square must match the en-passant square (enemy pawn one rank behind is the
    // actual capture victim).
    if (rank_delta == forward and (file_delta == 1 or file_delta == -1)) {
        const target = board.board_state[to.rank][to.file];
        if (en_passant_square) |en_passant_position| {
            // Caller contract: ep target rank matches "the square a pawn passed over on
            // the opponent's prior double push" — rank 5 when white is the mover (black
            // pushed 6→4), rank 2 when black is the mover (white pushed 1→3). Defends
            // against drift in callers that forget to clear the one-ply window.
            std.debug.assert(
                (turn == .white and en_passant_position.rank == 5) or
                    (turn == .black and en_passant_position.rank == 2),
            );
            if (target == .empty and to.rank == en_passant_position.rank and to.file == en_passant_position.file) {
                const expected_enemy_pawn: Piece = switch (turn) {
                    .white => .black_pawn,
                    .black => .white_pawn,
                };
                std.debug.assert(board.board_state[from.rank][to.file] == expected_enemy_pawn);
                return .{
                    .en_passant = .{
                        .captured_pawn_at = .{ .rank = from.rank, .file = to.file },
                    },
                };
            }
        }

        if (target != .empty and target.color().? != turn) {
            // Back-rank capture is a capture-promotion.
            if (to.rank == 0 or to.rank == 7) {
                return .{ .promotion = .{ .capture = target } };
            }
            return .{ .capture = target };
        }
    }

    return error.InvalidMove;
}

fn pseudo_legal_knight(
    board: *const Board,
    from: Position,
    to: Position,
    turn: Color,
) !MoveEffect {
    const rank_delta = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    const abs_rank = @abs(rank_delta);
    const abs_file = @abs(file_delta);

    if ((abs_rank == 2 and abs_file == 1) or (abs_rank == 1 and abs_file == 2)) {
        const target_piece = board.board_state[to.rank][to.file];
        if (target_piece == .empty) {
            return .move_only;
        }

        if (target_piece.color().? != turn) {
            return .{ .capture = target_piece };
        }
    }

    return error.InvalidMove;
}

fn pseudo_legal_king(
    board: *const Board,
    from: Position,
    to: Position,
    turn: Color,
    castling_rights: CastlingRights,
) !MoveEffect {
    const rank_delta = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    const abs_rank = @abs(rank_delta);
    const abs_file = @abs(file_delta);

    const target_piece = board.board_state[to.rank][to.file];

    if (abs_rank <= 1 and abs_file <= 1 and (abs_rank + abs_file > 0)) {
        if (target_piece == .empty) {
            return .move_only;
        }

        if (target_piece.color().? != turn) {
            return .{ .capture = target_piece };
        }
    }

    // Only moves left are castling and they're allowed only if the king is on the home position.
    if ((turn == .white and !std.meta.eql(from, rules_shared.WHITE_KING_HOME_POSITION)) or
        (turn == .black and !std.meta.eql(from, rules_shared.BLACK_KING_HOME_POSITION)))
    {
        return error.InvalidMove;
    }

    // If no rights allow shortcircuit early.
    if (!castling_rights.white_kingside and !castling_rights.white_queenside and
        !castling_rights.black_kingside and !castling_rights.black_queenside)
    {
        return error.InvalidMove;
    }

    if (abs_rank == 0 and abs_file == 2) {
        // If the king was under attack, you can't castle.
        if (check_helper.in_check(board, turn)) {
            return error.InvalidMove;
        }

        const side: CastlingSide = if (file_delta > 0) .king_side else .queen_side;
        return switch (turn) {
            .white => switch (side) {
                .king_side => try_castle(board, from, turn, WHITE_KING_SIDE_PLAN, castling_rights.white_kingside),
                .queen_side => try_castle(board, from, turn, WHITE_QUEEN_SIDE_PLAN, castling_rights.white_queenside),
            },
            .black => switch (side) {
                .king_side => try_castle(board, from, turn, BLACK_KING_SIDE_PLAN, castling_rights.black_kingside),
                .queen_side => try_castle(board, from, turn, BLACK_QUEEN_SIDE_PLAN, castling_rights.black_queenside),
            },
        };
    }

    return error.InvalidMove;
}

/// Runs the per-case castling checks given a `CastlingPlan`. The caller has already verified the
/// king is on its home square and isn't currently in check.
fn try_castle(
    board: *const Board,
    from: Position,
    turn: Color,
    plan: CastlingPlan,
    right: bool,
) !MoveEffect {
    if (!right) {
        return error.InvalidMove;
    }

    // Rights imply the rook is home by invariant (any move off the corner, or capture of the rook
    // on the corner, clears the matching right). Hand-crafted positions can still set flags without
    // the rook actually being there — guard against that rather than trusting the invariant on a
    // cold hand-crafted input. Checked before the attack simulation so malformed fixtures bail
    // out of one array read instead of two full `in_check` sweeps.
    const expected_rook: Piece = if (turn == .white) .white_rook else .black_rook;
    if (board.board_state[plan.rank][plan.rook_from_file] != expected_rook) {
        return error.InvalidMove;
    }

    for (plan.between_files) |file| {
        if (board.board_state[plan.rank][file] != .empty) {
            return error.InvalidMove;
        }
    }

    for (plan.king_path_files) |file| {
        var scratch = board.*;
        scratch.move(from, .{ .rank = plan.rank, .file = file });
        if (check_helper.in_check(&scratch, turn)) {
            return error.InvalidMove;
        }
    }

    return .{
        .castling = .{
            .side = plan.side,
            .rook_from = .{ .rank = plan.rank, .file = plan.rook_from_file },
            .rook_to = .{ .rank = plan.rank, .file = plan.rook_to_file },
        },
    };
}

/// Validates a sliding piece move: determines the direction from `from` to `to`, checks it's in
/// the allowed set, then walks the ray to verify the path is clear.
fn pseudo_legal_sliding(
    board: *const Board,
    from: Position,
    to: Position,
    turn: Color,
    allowed_directions: []const Direction,
) !MoveEffect {
    const rank_delta: i8 = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta: i8 = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    if (rank_delta == 0 and file_delta == 0) {
        return error.InvalidMove;
    }

    // Determine the direction.
    const direction: Direction = blk: {
        if (file_delta == 0) {
            break :blk if (rank_delta > 0) .north else .south;
        }
        if (rank_delta == 0) {
            break :blk if (file_delta > 0) .east else .west;
        }
        // Diagonals require equal absolute deltas.
        const abs_rank = @abs(rank_delta);
        const abs_file = @abs(file_delta);
        if (abs_rank != abs_file) {
            return error.InvalidMove;
        }

        if (rank_delta > 0 and file_delta > 0) break :blk .north_east;
        if (rank_delta > 0 and file_delta < 0) break :blk .north_west;
        if (rank_delta < 0 and file_delta > 0) break :blk .south_east;
        break :blk .south_west;
    };

    // Check the direction is in the allowed set.
    var allowed = false;
    for (allowed_directions) |allowed_direction| {
        if (allowed_direction == direction) {
            allowed = true;
            break;
        }
    }
    if (!allowed) {
        return error.InvalidMove;
    }

    // Walk the ray from `from` toward `to`, checking that all intermediate squares are empty.
    const delta = direction.deltas();
    var rank: i8 = @as(i8, @intCast(from.rank)) + delta.rank;
    var file: i8 = @as(i8, @intCast(from.file)) + delta.file;

    while (rank >= 0 and rank <= 7 and file >= 0 and file <= 7) {
        if (@as(u3, @intCast(rank)) == to.rank and @as(u3, @intCast(file)) == to.file) {
            const target_piece = board.board_state[to.rank][to.file];
            if (target_piece == .empty) {
                return .move_only;
            }

            if (target_piece.color().? != turn) {
                return .{ .capture = target_piece };
            }
            // No need to travel any further this was the target square after all.
            break;
        }
        if (board.board_state[@intCast(rank)][@intCast(file)] != .empty) {
            return error.InvalidMove; // Blocked.
        }
        rank += delta.rank;
        file += delta.file;
    }

    return error.InvalidMove; // Walked off the board without reaching target.
}

/// Returns the updated castling rights after `move` with `effect` is applied to a board whose
/// current rights are `current`. `board` must be the pre-apply board (used to read the mover
/// piece at `move.from`).
pub fn castling_rights_after(
    board: *const Board,
    turn: Color,
    move: Move,
    effect: MoveEffect,
    current: CastlingRights,
) CastlingRights {
    const moving_piece = board.board_state[move.from.rank][move.from.file];
    std.debug.assert(moving_piece != .empty);
    std.debug.assert(moving_piece.color().? == turn);

    // Once all four flags are off they're a fixed point — no later move can resurrect a right.
    // Skips the whole switch during late games where the rights are likely long gone.
    if (!current.white_kingside and !current.white_queenside and
        !current.black_kingside and !current.black_queenside)
    {
        return current;
    }

    var rights = current;
    switch (effect) {
        // Castling forfeits both of the mover's rights. The opponent's rights can't change —
        // you can't castle onto an opposing rook's home square.
        .castling => switch (turn) {
            .white => {
                rights.white_kingside = false;
                rights.white_queenside = false;
            },
            .black => {
                rights.black_kingside = false;
                rights.black_queenside = false;
            },
        },
        // Capture: mover-side logic is identical to .move_only, plus — if a rook was the one
        // captured and it was sitting on its home corner — the defender's rights on that side
        // clip. Only rook captures can touch castling rights; the is-rook guard keeps the
        // intent legible at the call site.
        .capture => |captured_piece| {
            std.debug.assert(captured_piece.color().? != turn);
            clear_mover_rights(moving_piece, move.from, &rights);
            if (captured_piece == .white_rook or captured_piece == .black_rook) {
                clear_rights_if_rook_captured_at_corner(captured_piece, move.to, &rights);
            }
        },
        // Promotion: mover is always a pawn (never king/rook), so mover-side rights are
        // unaffected. But a capture-promotion on a rook's home corner still clips the
        // defender's rights on that side — same shape as .capture minus the mover leg.
        .promotion => |promotion| {
            std.debug.assert(moving_piece == .white_pawn or moving_piece == .black_pawn);
            if (promotion.capture) |captured_piece| {
                if (captured_piece == .white_rook or captured_piece == .black_rook) {
                    clear_rights_if_rook_captured_at_corner(captured_piece, move.to, &rights);
                }
            }
        },
        .move_only => clear_mover_rights(moving_piece, move.from, &rights),
        // Pawn double-push and en-passant are pawn moves — they never touch king/rook rights.
        .pawn_double_push, .en_passant => {},
    }
    return rights;
}

/// Clears the *mover's* castling rights when the moving piece is a king (both sides) or a rook
/// leaving its home corner (matching side only). All other pieces are a no-op.
fn clear_mover_rights(piece: Piece, from: Position, rights: *CastlingRights) void {
    switch (piece) {
        .white_king => {
            rights.white_kingside = false;
            rights.white_queenside = false;
        },
        .black_king => {
            rights.black_kingside = false;
            rights.black_queenside = false;
        },
        .white_rook => {
            if (from.rank == 0) {
                if (from.file == 0) {
                    rights.white_queenside = false;
                }
                if (from.file == 7) {
                    rights.white_kingside = false;
                }
            }
        },
        .black_rook => {
            if (from.rank == 7) {
                if (from.file == 0) {
                    rights.black_queenside = false;
                }
                if (from.file == 7) {
                    rights.black_kingside = false;
                }
            }
        },
        else => {},
    }
}

// I couldn't think of a shorter name, this reads like a full sentence, and it's atrocious, but we
// all must face our demons this one is mine!!
/// Given that a rook was captured on `to`, clears the defender's castling right on that side if
/// `to` is the rook's home corner. This is a no-op for captures of rooks that have already left
/// their starting square — those rooks' castling rights are already forfeit from the earlier
/// move-off-corner, so there's nothing to clear here. The `if_..._at_corner` in the name calls
/// out that mid-board rook captures fall through silently.
fn clear_rights_if_rook_captured_at_corner(captured_rook: Piece, to: Position, rights: *CastlingRights) void {
    std.debug.assert(captured_rook == .white_rook or captured_rook == .black_rook);
    if (captured_rook == .white_rook and to.rank == 0) {
        if (to.file == 0) {
            rights.white_queenside = false;
        }
        if (to.file == 7) {
            rights.white_kingside = false;
        }
    } else if (captured_rook == .black_rook and to.rank == 7) {
        if (to.file == 0) {
            rights.black_queenside = false;
        }
        if (to.file == 7) {
            rights.black_kingside = false;
        }
    }
}

/// Applies a MoveEffect to a scratch Board copy. Used by the self-check simulation — a plain
/// Board.move(from, to) is wrong for en-passant (victim pawn stays on the board) and castling
/// (rook doesn't move). Callers use this on a stack-copy of the real Board.
///
/// Promotion is a no-op here beyond the base move: self-check only cares whether the mover's
/// king is attacked, and our own pieces never attack our own king — so the target-square piece
/// identity doesn't matter for that determination.
fn apply_effect(scratch: *Board, move: Move, effect: MoveEffect) void {
    scratch.move(move.from, move.to);
    switch (effect) {
        .move_only, .pawn_double_push, .capture, .promotion => {},
        .en_passant => |ep| {
            scratch.clear(ep.captured_pawn_at);
        },
        .castling => |castling| {
            scratch.move(castling.rook_from, castling.rook_to);
        },
    }
}

/// Filters pseudo-legal moves down to truly legal ones by discarding any move that would leave the
/// moving side's king in check. Works for all piece types — pinned pieces, king walking into
/// attacked squares, discovered checks on yourself, etc. are all caught by the simulate-and-test
/// approach.
///
/// `en_passant_square` is threaded in so EP candidates get the victim-pawn clear on the scratch
/// board. Without it, a pinned en-passant (horizontal discovered-check puzzle) would slip
/// through because the victim pawn stays on the scratch rank and blocks the pinning ray.
fn filter_self_check(
    board: *const Board,
    turn: Color,
    en_passant_square: ?Position,
    candidates: *const BoundedArray(Move, MAX_LEGAL_MOVES),
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (candidates.slice()) |candidate| {
        // Kings are never captured — checkmate ends the game first. Drop pseudo-legal moves
        // that would take the opposing king (only reachable from hand-crafted positions where
        // the opponent left their king en-prise on their own turn).
        const target = board.board_state[candidate.to.rank][candidate.to.file];
        if (target == .white_king or target == .black_king) {
            continue;
        }

        // Stack copy so we don't mutate the real board. The copy is cheap — it's just an 8×8
        // array of i8 on the stack.
        // I tried changing from copy to just mutate-retract, but that didn't come with any
        // visible benefit over this in terms of performance, and added more on my plate to always
        // remember to retract.
        var scratch = board.*;
        scratch.move(candidate.from, candidate.to);

        // EP recognition by shape: pawn moving diagonally onto the declared ep square (which
        // is guaranteed empty). The victim pawn sits on the candidate's starting rank, same
        // file as the ep target — clear it so `in_check` sees the correct post-capture board.
        if (en_passant_square) |ep| {
            const mover = board.board_state[candidate.from.rank][candidate.from.file];
            const mover_is_pawn = mover == .white_pawn or mover == .black_pawn;
            const lands_on_ep = candidate.to.rank == ep.rank and candidate.to.file == ep.file;
            const is_diagonal = candidate.from.file != candidate.to.file;
            if (mover_is_pawn and lands_on_ep and is_diagonal and target == .empty) {
                scratch.clear(.{ .rank = candidate.from.rank, .file = ep.file });
            }
        }

        if (!check_helper.in_check(&scratch, turn)) {
            out.append_assume_capacity(candidate);
        }
    }
}

/// Checks if there is any legal en passant move for the player given the board state and the en
/// passant square.
pub fn en_passant_capturable(
    board: *const Board,
    turn: Color,
    en_passant_square: ?Position,
) bool {
    const ep = en_passant_square orelse return false;
    // Invariant: ep target sits one square behind the last pawn double-push — rank 5 when white
    // is to move (black just pushed rank 6 → 4) or rank 2 when black is to move (white just
    // pushed rank 1 → 3). Mirrors the stronger assert in `en_passant_move`; catches a stale ep
    // target leaking from the wrong side's window.
    std.debug.assert(
        (turn == .white and ep.rank == 5) or
            (turn == .black and ep.rank == 2),
    );

    const captured_pawn_rank: u3 = if (turn == .white) 4 else 3;
    const captured_pawn: Piece = if (turn == .white) .black_pawn else .white_pawn;
    const own_pawn: Piece = if (turn == .white) .white_pawn else .black_pawn;

    if (board.board_state[captured_pawn_rank][ep.file] != captured_pawn) {
        return false;
    }
    const captured_pos = Position{ .rank = captured_pawn_rank, .file = ep.file };

    // `file` is u3: bounds-guard before subtracting/adding 1 to avoid safe-mode overflow panics.
    if (ep.file > 0) {
        const from = Position{ .rank = captured_pawn_rank, .file = ep.file - 1 };
        if (board.board_state[from.rank][from.file] == own_pawn and
            ep_capture_leaves_king_safe(board, turn, from, ep, captured_pos))
        {
            return true;
        }
    }

    if (ep.file < 7) {
        const from = Position{ .rank = captured_pawn_rank, .file = ep.file + 1 };
        if (board.board_state[from.rank][from.file] == own_pawn and
            ep_capture_leaves_king_safe(board, turn, from, ep, captured_pos))
        {
            return true;
        }
    }
    return false;
}

/// True if the EP capture leaves the capturer's king out of check. Delegates the scratch-board
/// mutation to `apply_effect` so the `.en_passant` handling stays single-sourced — see gotcha
/// G9: parallel scratch-apply sites drift silently when MoveEffect semantics grow.
fn ep_capture_leaves_king_safe(
    board: *const Board,
    turn: Color,
    from: Position,
    ep_target: Position,
    captured_pawn_at: Position,
) bool {
    var scratch = board.*;
    apply_effect(
        &scratch,
        .{ .from = from, .to = ep_target },
        .{ .en_passant = .{ .captured_pawn_at = captured_pawn_at } },
    );
    return !check_helper.in_check(&scratch, turn);
}

// --- Aggregate per-color movegen — does NOT compute MoveEffect ----------------------------------
/// Returns all of the legal moves of the piece at given `from`. `from` must hold a non-empty
/// piece — calling on an empty square is a programmer bug. The intermediate pseudo-legal buffer
/// lives on this function's stack frame (~1 KB); bench A/B confirmed there's no win in hoisting
/// it to the caller (see tmp/zig-review-local-mate-castling/bench_AB_comparison.md).
pub fn piece_legal_moves(
    board: *const Board,
    from: Position,
    castling_rights: CastlingRights,
    en_passant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    std.debug.assert(out.len == 0);

    var pseudo_legal: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};

    const piece = board.board_state[from.rank][from.file];
    std.debug.assert(piece != .empty);
    const turn = piece.color().?;

    switch (piece) {
        .white_pawn, .black_pawn => pawn_moves_from(board, from, turn, en_passant_square, &pseudo_legal),
        .white_knight, .black_knight => knight_moves_from(board, from, turn, &pseudo_legal),
        .white_bishop_light,
        .white_bishop_dark,
        .black_bishop_light,
        .black_bishop_dark,
        => bishop_moves_from(board, from, turn, &pseudo_legal),
        .white_rook, .black_rook => rook_moves_from(board, from, turn, &pseudo_legal),
        .white_queen, .black_queen => queen_moves_from(board, from, turn, &pseudo_legal),
        .white_king, .black_king => king_moves_from(board, from, turn, castling_rights, &pseudo_legal),
        .empty => unreachable,
    }

    filter_self_check(board, turn, en_passant_square, &pseudo_legal, out);
}

/// Appends single-push and double-push forward moves for one pawn at `from`. Does not
/// handle captures — those stay inline in `pawn_moves` because they share the capture_directions
/// loop. `start_rank` is 1 (white) or 6 (black); matches `from.rank` exactly when the pawn
/// can double-push.
fn pawn_forward_moves(
    board: *const Board,
    from: Position,
    target_rank: u3,
    start_rank: u3,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // Single push: target square must be empty.
    if (board.board_state[target_rank][from.file] == .empty) {
        out.append_assume_capacity(.{
            .from = from,
            .to = .{ .rank = target_rank, .file = from.file },
        });

        // Double push: only from starting rank, and the intermediate square must be empty
        // (which we just proved by entering this branch). start_rank is 1 or 6, so +/- 2
        // stays in u3 range.
        if (from.rank == start_rank) {
            const double_rank: u3 = switch (turn) {
                .white => from.rank + 2,
                .black => from.rank - 2,
            };
            if (board.board_state[double_rank][from.file] == .empty) {
                out.append_assume_capacity(.{
                    .from = from,
                    .to = .{ .rank = double_rank, .file = from.file },
                });
            }
        }
    }
}

/// Appends diagonal-capture moves for one pawn at `from`.
fn pawn_capture_moves(
    board: *const Board,
    from: Position,
    target_rank: u3,
    capture_directions: [2]Direction,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (capture_directions) |direction| {
        const file_delta = direction.deltas().file;
        // File is the only axis that can fall off the edge (a/h files). Rank is caller-pinned safe.
        const diag_file_i8: i8 = @as(i8, @intCast(from.file)) + file_delta;
        if (diag_file_i8 < 0 or diag_file_i8 > 7) {
            continue;
        }
        const diag_file: u3 = @intCast(diag_file_i8);
        const target_piece = board.board_state[target_rank][diag_file];

        // Regular capture — opponent piece on the diagonal.
        if (target_piece != .empty and target_piece.color().? != turn) {
            out.append_assume_capacity(.{
                .from = from,
                .to = .{ .rank = target_rank, .file = diag_file },
            });
        }
    }
}

/// Appends the en-passant capture for one pawn at `from`, if it's available.
fn en_passant_move(
    board: *const Board,
    turn: Color,
    from: Position,
    directions: [2]Direction,
    en_passant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const ep = en_passant_square orelse return;

    // The en-passant rank: rank 5 for white to move (black just pushed), rank 2 for black to move.
    std.debug.assert((turn == .white and ep.rank == 5) or (turn == .black and ep.rank == 2));

    // Both capture diagonals share a rank delta, so either index works.
    const rank_delta = directions[0].deltas().rank;

    // The attacker sits one forward step behind the ep square — i.e. on the same rank as the
    // pushed pawn. i8 math dodges u3 overflow/underflow at the edges.
    const from_rank_i8: i8 = @intCast(from.rank);
    const ep_rank_i8: i8 = @intCast(ep.rank);
    if (from_rank_i8 + rank_delta != ep_rank_i8) {
        return;
    }

    // The attacker's file must be adjacent to the ep square. The two capture diagonals carry
    // file deltas of +1 and -1, so we test both. i8 dodges the u3 underflow when ep sits on
    // file 0 or 7.
    const from_file_i8: i8 = @intCast(from.file);
    const ep_file_i8: i8 = @intCast(ep.file);
    const file_delta1 = directions[0].deltas().file;
    const file_delta2 = directions[1].deltas().file;
    if (from_file_i8 != ep_file_i8 + file_delta1 and
        from_file_i8 != ep_file_i8 + file_delta2)
    {
        return;
    }

    // The enemy pawn being captured must actually be sitting where en-passant expects it — same
    // rank as the attacker, same file as the ep target.
    const expected_enemy_pawn: Piece = switch (turn) {
        .white => .black_pawn,
        .black => .white_pawn,
    };
    std.debug.assert(board.board_state[from.rank][ep.file] == expected_enemy_pawn);

    out.append_assume_capacity(.{ .from = from, .to = ep });
}

/// Pseudo-legal moves for a single pawn at `from`. Covers single push, double push (from the
/// starting rank only), diagonal captures, and en-passant. The self-check filter applied by the
/// caller handles pins and moves that would leave our own king in check.
fn pawn_moves_from(
    board: *const Board,
    from: Position,
    turn: Color,
    en_passant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // Pawns on rank 0 or 7 would have been promoted already. Also the load-bearing guarantee
    // for the u3 arithmetic below: rank 1..6 + 1 stays 2..7, rank 1..6 - 1 stays 0..5.
    std.debug.assert(from.rank != 0 and from.rank != 7);

    const capture_directions: [2]Direction = switch (turn) {
        .white => rules_shared.WHITE_PAWN_CAPTURE_DIRECTIONS,
        .black => rules_shared.BLACK_PAWN_CAPTURE_DIRECTIONS,
    };
    const start_rank: u3 = switch (turn) {
        .white => 1,
        .black => 6,
    };
    const target_rank: u3 = switch (turn) {
        .white => from.rank + 1,
        .black => from.rank - 1,
    };

    pawn_forward_moves(board, from, target_rank, start_rank, turn, out);
    pawn_capture_moves(board, from, target_rank, capture_directions, turn, out);
    en_passant_move(board, turn, from, capture_directions, en_passant_square, out);
}

/// Pseudo-legal moves for a single knight at `from`.
fn knight_moves_from(
    board: *const Board,
    from: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const rank: i8 = @intCast(from.rank);
    const file: i8 = @intCast(from.file);

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
            .from = from,
            .to = .{ .rank = @intCast(target_rank), .file = @intCast(target_file) },
        });
    }
}

/// Pseudo-legal moves for a single bishop at `from`.
fn bishop_moves_from(
    board: *const Board,
    from: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (rules_shared.BISHOP_DIRECTIONS) |direction| {
        rules_shared.collect_ray_moves(board, from, direction, turn, out);
    }
}

/// Pseudo-legal moves for a single rook at `from`.
fn rook_moves_from(
    board: *const Board,
    from: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (rules_shared.ROOK_DIRECTIONS) |direction| {
        rules_shared.collect_ray_moves(board, from, direction, turn, out);
    }
}

/// Pseudo-legal moves for a single queen at `from`.
fn queen_moves_from(
    board: *const Board,
    from: Position,
    turn: Color,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    for (rules_shared.ALL_DIRECTIONS) |direction| {
        rules_shared.collect_ray_moves(board, from, direction, turn, out);
    }
}

/// Pseudo-legal moves for the king at `from`. Covers the eight one-step directions and
/// castling. Mirrors `pawn_moves_from`'s shape — the per-piece entry point bundles every kind
/// of king move, including the two-file castling slides, so callers don't have to know
/// castling is a distinct concern.
fn king_moves_from(
    board: *const Board,
    from: Position,
    turn: Color,
    castling_rights: CastlingRights,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const rank: i8 = @intCast(from.rank);
    const file: i8 = @intCast(from.file);

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
            .from = from,
            .to = .{ .rank = @intCast(target_rank), .file = @intCast(target_file) },
        });
    }

    king_castling_moves(board, from, turn, castling_rights, out);
}

/// Appends pseudo-legal castling moves for the king at `from`. Emits only the king's `from → to`
/// (landing file 6 for king-side, 2 for queen-side) — we deliberately do NOT emit a separate
/// rook move. A `Move` represents a single user-issued request, and castling is issued as the
/// king's two-file sideways slide; the companion rook relocation is derived at apply-time when
/// `preview_move` classifies the king's `abs_file == 2` move as castling and `try_castle`
/// returns `MoveEffect.castling.{rook_from, rook_to}` for `apply_effect` to consume.
///
/// Mirrors the castling preconditions from `try_castle`: right present, rook on its home square,
/// between-files empty, king not currently in check, and no king-path square under attack. The
/// caller's `filter_self_check` handles the landing-square-under-attack case post-move, but it
/// cannot see the "currently in check" rule or the "passes through attacked square" rule — so
/// we enforce those here.
fn king_castling_moves(
    board: *const Board,
    from: Position,
    turn: Color,
    castling_rights: CastlingRights,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    // King must be on its home square — castling is defined only from there.
    if ((turn == .white and !std.meta.eql(from, rules_shared.WHITE_KING_HOME_POSITION)) or
        (turn == .black and !std.meta.eql(from, rules_shared.BLACK_KING_HOME_POSITION)))
    {
        return;
    }

    // Short-circuit: with no rights on the mover's side, no castling option can be legal —
    // skips both the per-plan loop and the in_check sweep.
    const any_right = switch (turn) {
        .white => castling_rights.white_kingside or castling_rights.white_queenside,
        .black => castling_rights.black_kingside or castling_rights.black_queenside,
    };
    if (!any_right) {
        return;
    }

    // Can't castle out of check. The answer is the same for both plans, and it's the priciest
    // guard here — hoist it out of the loop.
    if (check_helper.in_check(board, turn)) {
        return;
    }

    const castling_options: [2]struct { plan: CastlingPlan, right: bool } = switch (turn) {
        .white => .{
            .{ .plan = WHITE_KING_SIDE_PLAN, .right = castling_rights.white_kingside },
            .{ .plan = WHITE_QUEEN_SIDE_PLAN, .right = castling_rights.white_queenside },
        },
        .black => .{
            .{ .plan = BLACK_KING_SIDE_PLAN, .right = castling_rights.black_kingside },
            .{ .plan = BLACK_QUEEN_SIDE_PLAN, .right = castling_rights.black_queenside },
        },
    };

    const expected_rook: Piece = switch (turn) {
        .white => .white_rook,
        .black => .black_rook,
    };

    option_loop: for (castling_options) |option| {
        if (!option.right) {
            continue;
        }

        const plan = option.plan;

        // Rights imply the rook is home by invariant (any move off the corner, or capture of
        // the rook on the corner, clears the matching right). Hand-crafted positions can still
        // set flags without the rook actually being there — guard against that here.
        if (board.board_state[plan.rank][plan.rook_from_file] != expected_rook) {
            continue;
        }

        for (plan.between_files) |file| {
            if (board.board_state[plan.rank][file] != .empty) {
                continue :option_loop;
            }
        }

        for (plan.king_path_files) |file| {
            var scratch = board.*;
            scratch.move(from, .{ .rank = plan.rank, .file = file });
            if (check_helper.in_check(&scratch, turn)) {
                continue :option_loop;
            }
        }

        // The landing file is fixed by side (6 / 2) — derive directly rather than indexing into
        // `king_path_files`, which would couple this emit to that array's last-element layout.
        const king_to_file: u3 = switch (plan.side) {
            .king_side => 6,
            .queen_side => 2,
        };
        out.append_assume_capacity(.{
            .from = from,
            .to = .{ .rank = plan.rank, .file = king_to_file },
        });
    }
}

/// Calculates the pseudo-legal pawn moves given the board state and color turn. Covers single push,
/// double push (from starting rank only), diagonal captures, and en-passant. The self-check filter
/// applied by the caller handles pins and moves that would leave our own king in check.
fn pawn_moves(
    board: *const Board,
    turn: Color,
    en_passant_square: ?Position,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const pawn_piece: Piece = switch (turn) {
        .black => .black_pawn,
        .white => .white_pawn,
    };

    const positions = board.find_piece_position(pawn_piece);
    for (positions.slice()) |position| {
        pawn_moves_from(board, position, turn, en_passant_square, out);
    }
}

/// Calculates the pseudo-legal knight moves given the board state. The self-check filter applied
/// by the caller handles pins and moves that would leave our own king in check.
fn knight_moves(board: *const Board, turn: Color, out: *BoundedArray(
    Move,
    MAX_LEGAL_MOVES,
)) void {
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
fn bishop_moves(board: *const Board, turn: Color, out: *BoundedArray(
    Move,
    MAX_LEGAL_MOVES,
)) void {
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
fn rook_moves(board: *const Board, turn: Color, out: *BoundedArray(
    Move,
    MAX_LEGAL_MOVES,
)) void {
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
fn queen_moves(board: *const Board, turn: Color, out: *BoundedArray(
    Move,
    MAX_LEGAL_MOVES,
)) void {
    const queen_piece: Piece = switch (turn) {
        .black => .black_queen,
        .white => .white_queen,
    };

    const positions = board.find_piece_position(queen_piece);
    for (positions.slice()) |position| {
        queen_moves_from(board, position, turn, out);
    }
}

/// Calculates pseudo-legal king moves — one square in any of the 8 directions, plus castling.
/// Moves onto empty squares or opponent-occupied squares (captures) are included; friendly-
/// occupied squares are skipped. The self-check filter applied by the caller handles the
/// "can't move into check" rule.
fn king_moves(
    board: *const Board,
    turn: Color,
    castling_rights: CastlingRights,
    out: *BoundedArray(Move, MAX_LEGAL_MOVES),
) void {
    const king_piece: Piece = switch (turn) {
        .white => .white_king,
        .black => .black_king,
    };

    const positions = board.find_piece_position(king_piece);
    std.debug.assert(positions.len == 1);

    king_moves_from(board, positions.slice()[0], turn, castling_rights, out);
}
// --- END aggregate movegen ----------------------------------------------------------------------

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_util = @import("test_util.zig");

test "piece_legal_moves filters pin: pinned white rook can only move along the pin ray" {
    // White king d1, white rook d2 pinned on d-file, black rook d8, black king h8.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 3 });
    test_util.place(&board, .white_rook, .{ .rank = 1, .file = 3 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 3 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });
    const castling: CastlingRights = .{};

    var rook_moves_only: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 1, .file = 3 }, castling, null, &rook_moves_only);

    // Every legal move for the pinned rook must stay on the d-file (file == 3).
    try testing.expect(rook_moves_only.len > 0);
    for (rook_moves_only.slice()) |mv| {
        try testing.expectEqual(@as(u3, 3), mv.to.file);
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
    king_moves(&board, .white, .{}, &out);

    for (out.slice()) |mv| {
        const to_d4 = mv.to.rank == 3 and mv.to.file == 3;
        const to_d5 = mv.to.rank == 4 and mv.to.file == 3;
        try testing.expect(!to_d4 and !to_d5);
    }
}

test "preview_move returns InvalidMove for a move from an empty square" {
    var board: Board = undefined;
    board.init();
    const castling: CastlingRights = .{};

    const mv = Move{
        .from = .{ .rank = 4, .file = 4 }, // e5, empty
        .to = .{ .rank = 5, .file = 4 }, // e6
    };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, castling, null));
}

test "preview_move rejects a move that would leave own king in check" {
    // Pin scenario: white king d1, white rook d2 (pinned on the d-file), black rook d8.
    // The pinned rook moving off the d-file exposes the king — preview_move's self-check
    // must catch this and return error.InvalidMove.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 3 }); // d1
    test_util.place(&board, .white_rook, .{ .rank = 1, .file = 3 }); // d2
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 3 }); // d8
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 }); // h8

    const illegal = Move{
        .from = .{ .rank = 1, .file = 3 },
        .to = .{ .rank = 1, .file = 4 }, // d2 → e2, off the pin ray
    };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, illegal, .{}, null));

    // Sanity: a rook move *along* the pin ray remains legal.
    const legal = Move{
        .from = .{ .rank = 1, .file = 3 },
        .to = .{ .rank = 2, .file = 3 }, // d2 → d3, stays on d-file
    };
    _ = try preview_move(&board, .white, legal, .{}, null);
}

test "piece_legal_moves on the king returns only moves with from == king_pos" {
    // Documents the contract: piece_legal_moves narrows to moves from the queried square.
    var board: Board = undefined;
    board.init();
    const castling: CastlingRights = .{};
    const king_pos = Position{ .rank = 0, .file = 4 };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, king_pos, castling, null, &out);

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

test "preview_move rejects capturing the opposing king" {
    // White rook e1, black king e4, white king a1 — hand-crafted position where black left
    // the king en-prise. Rook→e4 is geometrically reachable but must be rejected.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 3, .file = 4 });
    const castling: CastlingRights = .{};

    const king_capture = Move{
        .from = .{ .rank = 0, .file = 4 },
        .to = .{ .rank = 3, .file = 4 },
    };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, king_capture, castling, null));

    // Sanity: a non-king target along the same ray still validates.
    const quiet_move = Move{
        .from = .{ .rank = 0, .file = 4 },
        .to = .{ .rank = 1, .file = 4 },
    };
    _ = try preview_move(&board, .white, quiet_move, castling, null);
}

test "piece_legal_moves never emits a king capture" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 3, .file = 4 });
    const castling: CastlingRights = .{};
    const black_king_pos = Position{ .rank = 3, .file = 4 };

    var rook_moves_only: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 0, .file = 4 }, castling, null, &rook_moves_only);
    var saw_e2 = false;
    var saw_e3 = false;
    for (rook_moves_only.slice()) |mv| {
        try testing.expect(!(mv.to.rank == black_king_pos.rank and mv.to.file == black_king_pos.file));
        if (mv.to.rank == 1 and mv.to.file == 4) {
            saw_e2 = true;
        }
        if (mv.to.rank == 2 and mv.to.file == 4) {
            saw_e3 = true;
        }
    }
    // Sanity: ray still produces the empty squares up to (but not through) the king.
    try testing.expect(saw_e2);
    try testing.expect(saw_e3);
}

test "castling_rights_after: king move clears both mover-side rights" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 5 } };
    const next = castling_rights_after(&board, .white, mv, .move_only, .{});

    try testing.expect(!next.white_kingside);
    try testing.expect(!next.white_queenside);
    try testing.expect(next.black_kingside);
    try testing.expect(next.black_queenside);
}

test "castling_rights_after: rook leaves home corner clears matching side only" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });

    const mv = Move{ .from = .{ .rank = 0, .file = 0 }, .to = .{ .rank = 0, .file = 3 } };
    const next = castling_rights_after(&board, .white, mv, .move_only, .{});

    try testing.expect(!next.white_queenside);
    try testing.expect(next.white_kingside);
    try testing.expect(next.black_kingside);
    try testing.expect(next.black_queenside);
}

test "castling_rights_after: capture of rook on home corner clears defender's side" {
    // White rook captures black rook at a8 — black_queenside must clear.
    var board = test_util.empty_board();
    test_util.place(&board, .white_rook, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    const mv = Move{ .from = .{ .rank = 7, .file = 4 }, .to = .{ .rank = 7, .file = 0 } };
    const next = castling_rights_after(&board, .white, mv, .{ .capture = .black_rook }, .{});

    try testing.expect(!next.black_queenside);
    try testing.expect(next.black_kingside);
    // Mover left e8 (not a rook home), so white rights survive.
    try testing.expect(next.white_kingside);
    try testing.expect(next.white_queenside);
}

test "castling_rights_after: promotion-capture on rook corner clears defender's rights" {
    // White pawn on b7 captures black rook on a8 and promotes — the capture-promotion path
    // must still clip black_queenside. Regression guard: the prior implementation's else =>{}
    // arm silently swallowed this effect.
    var board = test_util.empty_board();
    test_util.place(&board, .white_pawn, .{ .rank = 6, .file = 1 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    const mv = Move{ .from = .{ .rank = 6, .file = 1 }, .to = .{ .rank = 7, .file = 0 } };
    const effect: MoveEffect = .{ .promotion = .{ .capture = .black_rook } };
    const next = castling_rights_after(&board, .white, mv, effect, .{});

    try testing.expect(!next.black_queenside);
    try testing.expect(next.black_kingside);
    try testing.expect(next.white_kingside);
    try testing.expect(next.white_queenside);
}

test "castling_rights_after: all-rights-off input is a fixed point" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });
    const all_off: CastlingRights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 5 } };
    const next = castling_rights_after(&board, .white, mv, .move_only, all_off);

    try testing.expect(!next.white_kingside);
    try testing.expect(!next.white_queenside);
    try testing.expect(!next.black_kingside);
    try testing.expect(!next.black_queenside);
}

test "castling_rights_after: castling clears both mover-side rights, leaves defender alone" {
    // The `.castling` arm of the switch was pre-existing dead code until pseudo_legal_king started
    // emitting castling effects; this test locks its behaviour once the arm is reachable.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    const effect: MoveEffect = .{ .castling = .{
        .side = .king_side,
        .rook_from = .{ .rank = 0, .file = 7 },
        .rook_to = .{ .rank = 0, .file = 5 },
    } };
    const next = castling_rights_after(&board, .white, mv, effect, .{});

    try testing.expect(!next.white_kingside);
    try testing.expect(!next.white_queenside);
    try testing.expect(next.black_kingside);
    try testing.expect(next.black_queenside);
}

// ── Castling happy-path tests ─────────────────────────────────────────────────
// All four (colour × side) pairs exercise the full preview_move → pseudo_legal_king → try_castle
// chain on a minimal board: two kings and one rook. Minimal fixtures keep the self-check simulation
// trivially legal (no attackers on the king's final square).

test "preview_move: white kingside castling returns MoveEffect.castling with correct rook move" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    const effect = try preview_move(&board, .white, mv, .{}, null);

    try testing.expectEqual(CastlingSide.king_side, effect.castling.side);
    try testing.expectEqual(Position{ .rank = 0, .file = 7 }, effect.castling.rook_from);
    try testing.expectEqual(Position{ .rank = 0, .file = 5 }, effect.castling.rook_to);
}

test "preview_move: white queenside castling returns MoveEffect.castling with correct rook move" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 2 } };
    const effect = try preview_move(&board, .white, mv, .{}, null);

    try testing.expectEqual(CastlingSide.queen_side, effect.castling.side);
    try testing.expectEqual(Position{ .rank = 0, .file = 0 }, effect.castling.rook_from);
    try testing.expectEqual(Position{ .rank = 0, .file = 3 }, effect.castling.rook_to);
}

test "preview_move: black kingside castling returns MoveEffect.castling with correct rook move" {
    var board = test_util.empty_board();
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 7 });
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });

    const mv = Move{ .from = .{ .rank = 7, .file = 4 }, .to = .{ .rank = 7, .file = 6 } };
    const effect = try preview_move(&board, .black, mv, .{}, null);

    try testing.expectEqual(CastlingSide.king_side, effect.castling.side);
    try testing.expectEqual(Position{ .rank = 7, .file = 7 }, effect.castling.rook_from);
    try testing.expectEqual(Position{ .rank = 7, .file = 5 }, effect.castling.rook_to);
}

test "preview_move: black queenside castling returns MoveEffect.castling with correct rook move" {
    var board = test_util.empty_board();
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 7 });

    const mv = Move{ .from = .{ .rank = 7, .file = 4 }, .to = .{ .rank = 7, .file = 2 } };
    const effect = try preview_move(&board, .black, mv, .{}, null);

    try testing.expectEqual(CastlingSide.queen_side, effect.castling.side);
    try testing.expectEqual(Position{ .rank = 7, .file = 0 }, effect.castling.rook_from);
    try testing.expectEqual(Position{ .rank = 7, .file = 3 }, effect.castling.rook_to);
}

// ── Castling rejection-path tests ─────────────────────────────────────────────
// One guard per test so a failing refactor pinpoints which branch regressed.

test "preview_move: castling rejected when king is not on home square" {
    // White king on e4 (not home), tries a 2-square horizontal move with rights set.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 3, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    const mv = Move{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 3, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, .{}, null));
}

test "preview_move: castling rejected when all four rights are off" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    const all_off: CastlingRights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, all_off, null));
}

test "preview_move: castling rejected when king is currently in check" {
    // Black rook on e8 attacks white king on e1 through the open e-file — can't castle out of check.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 4 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, .{}, null));
}

test "preview_move: castling rejected when the matching side's right is false" {
    // Kingside right is off, queenside on — kingside attempt must still fail.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    const rights: CastlingRights = .{ .white_kingside = false };

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, rights, null));
}

test "preview_move: castling rejected when a between-files square is occupied" {
    // White knight on f1 blocks the kingside path.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .white_knight, .{ .rank = 0, .file = 5 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, .{}, null));
}

test "preview_move: castling rejected when a king-path square is attacked" {
    // Black rook on f8 attacks f1 — the king's first transit square — kingside must be refused.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 5 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, .{}, null));
}

test "preview_move: castling rejected when rook is missing from home corner" {
    // Hand-crafted position: rights set but h1 is empty. Defensive rook-home check must fire.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, .{}, null));
}

test "preview_move: queenside castling rejected when b-file has a blocker" {
    // b1 is in `between_files` but not `king_path_files` — this test locks the distinction:
    // a blocker on b1 must reject the move even though the king never stands there.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_knight, .{ .rank = 0, .file = 1 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 2 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, .{}, null));
}

// ── is_checkmate / is_stalemate ───────────────────────────────────────────────
// Lock down the new game-status detection. Each fixture is the smallest legal position that
// exercises one branch of has_any_legal_move + the in_check pre-condition.

test "is_checkmate: classic back-rank mate is detected for black" {
    // Black king h8 with friendly pawns f7/g7/h7 trapping it on the back rank; white rook on
    // e8 delivers check along rank 7. None of black's pieces can capture, block, or escape.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 5 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 6 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 7 });

    try testing.expect(is_checkmate(&board, .black, .{}, null));
    try testing.expect(!is_stalemate(&board, .black, .{}, null));
}

test "is_checkmate: returns false when king has an escape square" {
    // Same back-rank position minus the h7 pawn — h7 is now an unattacked escape square,
    // so the position is check but not mate.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 5 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 6 });

    try testing.expect(!is_checkmate(&board, .black, .{}, null));
}

test "is_checkmate: returns false when not in check (stalemate-shaped position)" {
    // Same fixture as the stalemate test below — black has no moves but isn't in check.
    // is_checkmate must short-circuit on the in_check pre-condition and return false.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 6, .file = 5 });
    test_util.place(&board, .white_queen, .{ .rank = 5, .file = 6 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    try testing.expect(!is_checkmate(&board, .black, .{}, null));
}

test "is_stalemate: king-in-corner trapped by opposing king + queen, no check" {
    // Black king h8; white king f7 controls g7/g8; white queen g6 covers h7 (NE diagonal one step)
    // and reinforces g7/g8. h8 itself is unattacked — black is not in check.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 6, .file = 5 });
    test_util.place(&board, .white_queen, .{ .rank = 5, .file = 6 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });

    try testing.expect(is_stalemate(&board, .black, .{}, null));
    try testing.expect(!is_checkmate(&board, .black, .{}, null));
}

test "is_stalemate: returns false when in check (would be checkmate, not stalemate)" {
    // Reuse the back-rank mate fixture — black is mated, but the question here is just "is
    // this stalemate?" — the answer must be false because the side-to-move is in check.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 5 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 6 });
    test_util.place(&board, .black_pawn, .{ .rank = 6, .file = 7 });

    try testing.expect(!is_stalemate(&board, .black, .{}, null));
}

test "is_stalemate: returns false when the side has any legal move" {
    // Starting position — white has 20 legal opening moves. Sanity guard so a regression in
    // has_any_legal_move's "found one, return true" early-exit doesn't sneak past the
    // narrower fixtures above.
    var board: Board = undefined;
    board.init();

    try testing.expect(!is_stalemate(&board, .white, .{}, null));
    try testing.expect(!is_checkmate(&board, .white, .{}, null));
}

// ── king castling movegen via piece_legal_moves ────────────────────────────────
// `try_castle` (the per-move validator) is exhaustively covered by the preview_move tests
// above. These tests pin the *enumeration* path: piece_legal_moves on the king must surface
// the available castling slides.

test "piece_legal_moves: white king with both rights and clear path emits g1 and c1" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 0, .file = 4 }, .{}, null, &out);

    var saw_kingside = false;
    var saw_queenside = false;
    for (out.slice()) |mv| {
        if (mv.to.rank == 0 and mv.to.file == 6) saw_kingside = true;
        if (mv.to.rank == 0 and mv.to.file == 2) saw_queenside = true;
    }
    try testing.expect(saw_kingside);
    try testing.expect(saw_queenside);
}

test "piece_legal_moves: kingside-only right emits g1 but not c1" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    const rights: CastlingRights = .{ .white_queenside = false };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 0, .file = 4 }, rights, null, &out);

    var saw_kingside = false;
    var saw_queenside = false;
    for (out.slice()) |mv| {
        if (mv.to.rank == 0 and mv.to.file == 6) saw_kingside = true;
        if (mv.to.rank == 0 and mv.to.file == 2) saw_queenside = true;
    }
    try testing.expect(saw_kingside);
    try testing.expect(!saw_queenside);
}

test "piece_legal_moves: king in check emits no castling moves" {
    // Black rook on e3 puts the white king on e1 in check. king_castling_moves's
    // up-front in_check guard must fire — no castling moves should appear, even though the
    // matching rights are set and the rook is home.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_rook, .{ .rank = 2, .file = 4 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 0, .file = 4 }, .{}, null, &out);

    for (out.slice()) |mv| {
        const is_kingside_castle = mv.to.rank == 0 and mv.to.file == 6;
        const is_queenside_castle = mv.to.rank == 0 and mv.to.file == 2;
        try testing.expect(!is_kingside_castle and !is_queenside_castle);
    }
}

test "piece_legal_moves: black king with both rights emits g8 and c8" {
    // Mirror of the white test on rank 7.
    var board = test_util.empty_board();
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 7 });
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 7, .file = 4 }, .{}, null, &out);

    var saw_kingside = false;
    var saw_queenside = false;
    for (out.slice()) |mv| {
        if (mv.to.rank == 7 and mv.to.file == 6) saw_kingside = true;
        if (mv.to.rank == 7 and mv.to.file == 2) saw_queenside = true;
    }
    try testing.expect(saw_kingside);
    try testing.expect(saw_queenside);
}

test "piece_legal_moves: rook missing from corner suppresses that side's castling" {
    // White kingside right is set but h1 is empty. king_castling_moves's defensive rook-home
    // check must skip kingside while still emitting queenside (a1 is occupied).
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 0, .file = 4 }, .{}, null, &out);

    var saw_kingside = false;
    var saw_queenside = false;
    for (out.slice()) |mv| {
        if (mv.to.rank == 0 and mv.to.file == 6) saw_kingside = true;
        if (mv.to.rank == 0 and mv.to.file == 2) saw_queenside = true;
    }
    try testing.expect(!saw_kingside);
    try testing.expect(saw_queenside);
}

// ── en-passant movegen via piece_legal_moves ───────────────────────────────────
// pseudo_legal_pawn covers the per-move validator path; these tests pin the *enumeration*
// path: piece_legal_moves on the attacking pawn must surface the ep capture.

test "piece_legal_moves: white pawn on e5 emits ep capture to d6 when ep target is set" {
    // Black just played d7-d5 (double push), so ep target = d6 = (5, 3). The white pawn on
    // e5 = (4, 4) is positioned to capture en-passant.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 4 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 3 });
    const ep: Position = .{ .rank = 5, .file = 3 };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 4, .file = 4 }, .{}, ep, &out);

    var saw_ep = false;
    for (out.slice()) |mv| {
        if (mv.to.rank == 5 and mv.to.file == 3) saw_ep = true;
    }
    try testing.expect(saw_ep);
}

test "piece_legal_moves: black pawn on d4 emits ep capture to e3 when ep target is set" {
    // White just played e2-e4 (double push), so ep target = e3 = (2, 4). The black pawn on
    // d4 = (3, 3) can capture en-passant.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_pawn, .{ .rank = 3, .file = 3 });
    test_util.place(&board, .white_pawn, .{ .rank = 3, .file = 4 });
    const ep: Position = .{ .rank = 2, .file = 4 };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 3, .file = 3 }, .{}, ep, &out);

    var saw_ep = false;
    for (out.slice()) |mv| {
        if (mv.to.rank == 2 and mv.to.file == 4) saw_ep = true;
    }
    try testing.expect(saw_ep);
}

test "piece_legal_moves: ep target set but pawn not on the attack rank emits no ep move" {
    // White pawn sits on a2 (rank 1) with ep target on d6 (rank 5). The rank-delta guard in
    // en_passant_move filters this out — no move with `to == d6` should appear.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 1, .file = 0 });
    const ep: Position = .{ .rank = 5, .file = 3 };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 1, .file = 0 }, .{}, ep, &out);

    for (out.slice()) |mv| {
        try testing.expect(!(mv.to.rank == 5 and mv.to.file == 3));
    }
}

test "piece_legal_moves: ep target on adjacent file but wrong distance emits no ep move" {
    // White pawn on a4 (rank 3, file 0); ep target on h5 (rank 4, file 7). Rank delta passes
    // (3+1=4=ep.rank) but the file isn't adjacent to ep.file. The file-delta guard must reject.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 0 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 7 });
    const ep: Position = .{ .rank = 5, .file = 7 };

    var out: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 4, .file = 0 }, .{}, ep, &out);

    for (out.slice()) |mv| {
        try testing.expect(!(mv.to.rank == 5 and mv.to.file == 7));
    }
}

// --- en_passant_capturable --------------------------------------------------

test "en_passant_capturable: null ep square returns false" {
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    try testing.expect(!en_passant_capturable(&board, .white, null));
    try testing.expect(!en_passant_capturable(&board, .black, null));
}

test "en_passant_capturable: white to move, adjacent white pawn can legally capture" {
    // Black just played e7→e5. White pawn sits on d5 (rank 4, file 3). EP target = e6 (rank 5, file 4).
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 4 }); // e5 captured pawn
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 3 }); // d5 capturer

    try testing.expect(en_passant_capturable(&board, .white, .{ .rank = 5, .file = 4 }));
}

test "en_passant_capturable: black to move, adjacent black pawn can legally capture" {
    // White just played e2→e4. Black pawn sits on d4 (rank 3, file 3). EP target = e3 (rank 2, file 4).
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 3, .file = 4 }); // e4 captured pawn
    test_util.place(&board, .black_pawn, .{ .rank = 3, .file = 3 }); // d4 capturer

    try testing.expect(en_passant_capturable(&board, .black, .{ .rank = 2, .file = 4 }));
}

test "en_passant_capturable: no adjacent own pawn returns false" {
    // Black just pushed e7→e5 but no white pawn is on d5 or f5.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 4 });

    try testing.expect(!en_passant_capturable(&board, .white, .{ .rank = 5, .file = 4 }));
}

test "en_passant_capturable: pin-bound capture (discovered check) returns false" {
    // Classic horizontal-pin EP puzzle. White king, capturing pawn, captured pawn, and a
    // black rook all share rank 5 (rank-index 4). The EP capture removes both pawns from
    // that rank, exposing a clear line from the white king to the rook — illegal.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 4, .file = 0 }); // a5
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 1 }); // b5 capturer
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 2 }); // c5 captured
    test_util.place(&board, .black_rook, .{ .rank = 4, .file = 7 }); // h5 pinning

    // EP target is c6 (rank-index 5, file 2). Only candidate is white's b5×c6.
    try testing.expect(!en_passant_capturable(&board, .white, .{ .rank = 5, .file = 2 }));
}

test "en_passant_capturable: a-file EP target, only right-neighbour path valid" {
    // Black pushed a7→a5. White pawn on b5 captures via a6.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 0 }); // a5
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 1 }); // b5

    try testing.expect(en_passant_capturable(&board, .white, .{ .rank = 5, .file = 0 }));
}

test "en_passant_capturable: h-file EP target, only left-neighbour path valid" {
    // Black pushed h7→h5. White pawn on g5 captures via h6.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 4 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 7 }); // h5
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 6 }); // g5

    try testing.expect(en_passant_capturable(&board, .white, .{ .rank = 5, .file = 7 }));
}

test "en_passant_capturable: capturers on BOTH adjacent files still returns true" {
    // Two white pawns flank the victim; either can make the capture. Guards against a
    // refactor that accidentally early-exits after inspecting only one branch.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 4 }); // e5 victim
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 3 }); // d5 left capturer
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 5 }); // f5 right capturer

    try testing.expect(en_passant_capturable(&board, .white, .{ .rank = 5, .file = 4 }));
}

test "en_passant_capturable: capturer present but victim pawn missing returns false" {
    // Adjacent own pawn exists, but nothing on the captured-pawn-rank at ep.file.
    // Covers the `board_state[captured_pawn_rank][ep.file] != captured_pawn` early-exit.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 3 }); // d5 capturer only

    try testing.expect(!en_passant_capturable(&board, .white, .{ .rank = 5, .file = 4 }));
}

test "piece_legal_moves: pin-bound EP is filtered out (horizontal discovered-check)" {
    // Same fixture as the pin-bound `en_passant_capturable` test. Before the
    // `filter_self_check` fix, the victim pawn stayed on the scratch board and blocked the
    // pinning ray, so `piece_legal_moves` wrongly accepted the EP. The fix clears the victim
    // on the scratch copy when a pawn lands diagonally on the declared ep target.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 4, .file = 0 }); // a5
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .white_pawn, .{ .rank = 4, .file = 1 }); // b5 capturer
    test_util.place(&board, .black_pawn, .{ .rank = 4, .file = 2 }); // c5 victim
    test_util.place(&board, .black_rook, .{ .rank = 4, .file = 7 }); // h5 pinner

    var legal: BoundedArray(Move, MAX_LEGAL_MOVES) = .{};
    piece_legal_moves(&board, .{ .rank = 4, .file = 1 }, .{}, .{ .rank = 5, .file = 2 }, &legal);

    for (legal.slice()) |mv| {
        try testing.expect(!(mv.to.rank == 5 and mv.to.file == 2));
    }
}
