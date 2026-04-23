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
    enpassant_square: ?Position,
    castling_rights: CastlingRights,
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
        .white_pawn, .black_pawn => pseudo_legal_pawn(board, from, to, turn, enpassant_square),
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

    for (plan.between_files) |f| {
        if (board.board_state[plan.rank][f] != .empty) {
            return error.InvalidMove;
        }
    }

    for (plan.king_path_files) |f| {
        var scratch = board.*;
        scratch.move(from, .{ .rank = plan.rank, .file = f });
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
    allowed_directions: []const rules_shared.Direction,
) !MoveEffect {
    const rank_delta: i8 = @as(i8, @intCast(to.rank)) - @as(i8, @intCast(from.rank));
    const file_delta: i8 = @as(i8, @intCast(to.file)) - @as(i8, @intCast(from.file));

    if (rank_delta == 0 and file_delta == 0) {
        return error.InvalidMove;
    }

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
    for (allowed_directions) |d| {
        if (d == direction) {
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
        .promotion => |p| {
            std.debug.assert(moving_piece == .white_pawn or moving_piece == .black_pawn);
            if (p.capture) |captured_piece| {
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
        .castling => |c| {
            scratch.move(c.rook_from, c.rook_to);
        },
    }
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

        if (!check_helper.in_check(&scratch, turn)) {
            out.append_assume_capacity(candidate);
        }
    }
}

// --- TODO: Refactor to respect MoveEffect -------
// Everything below predates the preview_move-centric design.

/// Returns all of the legal moves of the piece at given position. Position must hold a non-empty
/// piece — calling on an empty square is a programmer bug.
pub fn piece_legal_moves(
    board: *const Board,
    position: Position,
    castling_rights: CastlingRights,
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

// TODO: Castling will be added here once CastlingRights is fleshed out.
/// Calculates pseudo-legal king moves — one square in any of the 8 directions. Moves onto empty
/// squares or opponent-occupied squares (captures) are included. Friendly-occupied squares are
/// skipped. The self-check filter applied by the caller handles the "can't move into check" rule.
fn king_moves(board: *const Board, turn: Color, out: *BoundedArray(
    Move,
    MAX_LEGAL_MOVES,
)) void {
    const king_piece: Piece = switch (turn) {
        .white => .white_king,
        .black => .black_king,
    };

    const positions = board.find_piece_position(king_piece);
    std.debug.assert(positions.len == 1);

    king_moves_from(board, positions.slice()[0], turn, out);
}
// --- TODO END ---

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
    king_moves(&board, .white, &out);

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
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, castling));
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
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, illegal, null, .{}));

    // Sanity: a rook move *along* the pin ray remains legal.
    const legal = Move{
        .from = .{ .rank = 1, .file = 3 },
        .to = .{ .rank = 2, .file = 3 }, // d2 → d3, stays on d-file
    };
    _ = try preview_move(&board, .white, legal, null, .{});
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
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, king_capture, null, castling));

    // Sanity: a non-king target along the same ray still validates.
    const quiet_move = Move{
        .from = .{ .rank = 0, .file = 4 },
        .to = .{ .rank = 1, .file = 4 },
    };
    _ = try preview_move(&board, .white, quiet_move, null, castling);
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
    const effect = try preview_move(&board, .white, mv, null, .{});

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
    const effect = try preview_move(&board, .white, mv, null, .{});

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
    const effect = try preview_move(&board, .black, mv, null, .{});

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
    const effect = try preview_move(&board, .black, mv, null, .{});

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
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, .{}));
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
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, all_off));
}

test "preview_move: castling rejected when king is currently in check" {
    // Black rook on e8 attacks white king on e1 through the open e-file — can't castle out of check.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 4 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, .{}));
}

test "preview_move: castling rejected when the matching side's right is false" {
    // Kingside right is off, queenside on — kingside attempt must still fail.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    const rights: CastlingRights = .{ .white_kingside = false };

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, rights));
}

test "preview_move: castling rejected when a between-files square is occupied" {
    // White knight on f1 blocks the kingside path.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .white_knight, .{ .rank = 0, .file = 5 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, .{}));
}

test "preview_move: castling rejected when a king-path square is attacked" {
    // Black rook on f8 attacks f1 — the king's first transit square — kingside must be refused.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });
    test_util.place(&board, .black_rook, .{ .rank = 7, .file = 5 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, .{}));
}

test "preview_move: castling rejected when rook is missing from home corner" {
    // Hand-crafted position: rights set but h1 is empty. Defensive rook-home check must fire.
    var board = test_util.empty_board();
    test_util.place(&board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&board, .black_king, .{ .rank = 7, .file = 0 });

    const mv = Move{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } };
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, .{}));
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
    try testing.expectError(error.InvalidMove, preview_move(&board, .white, mv, null, .{}));
}
