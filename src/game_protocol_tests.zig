//! Raw-event protocol tests for `Game.tick`. Drives the state machine one event at a time and
//! asserts on emitted effects directly — covers arms and edge cases the auto-ack helpers in
//! test_helpers.zig deliberately hide (intermediate proposing state, retry budget, nack paths,
//! Arm 4 send_nack flavors, the rejection matrix, the top-level unexpected-event counter).

const std = @import("std");
const game_mod = @import("game.zig");
const shared = @import("shared.zig");
const board_mod = @import("board.zig");
const test_util = @import("rule_engine/test_util.zig");
const BoundedArray = @import("bounded_array.zig").BoundedArray;

const Game = game_mod.Game;
const GameEvent = game_mod.GameEvent;
const GameEffect = game_mod.GameEffect;
const GameCommand = game_mod.GameCommand;
const GameResult = game_mod.GameResult;
const LogEntry = game_mod.LogEntry;
const Color = shared.Color;
const Move = shared.Move;
const Position = shared.Position;
const Piece = board_mod.Piece;
const testing = std.testing;

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Drives a single event through `tick` and returns the effects emitted. Each test calls this
/// per step so the caller can inspect both the post-event state and the per-step effect list.
fn drive_event(game: *Game, event: GameEvent) BoundedArray(GameEffect, Game.MAX_EFFECTS) {
    var out: BoundedArray(GameEffect, Game.MAX_EFFECTS) = .{};
    game.tick(event, &out);
    return out;
}

/// Wraps a `play` move in a local_command event with zero think/now timings. Most arm tests
/// don't care about timings; the few that do build the event inline.
fn local_play(move: Move) GameEvent {
    return .{ .local_command = .{
        .command = .{ .play = .{ .move = move, .promotion = null } },
        .think_time_ms = 0,
        .now_ms = 0,
    } };
}

/// Returns `true` if `effects` contains any effect of tag `tag`. Tests that just want a
/// presence check (e.g. "render fired") use this; tests that need the payload switch directly.
fn contains_tag(effects: BoundedArray(GameEffect, Game.MAX_EFFECTS), comptime tag: std.meta.Tag(GameEffect)) bool {
    for (effects.slice()) |effect| {
        if (effect == tag) return true;
    }
    return false;
}

// ── Arm 1: local_command in local_turn ──────────────────────────────────────

test "Arm 1: legal local_command transitions to proposing and emits send_proposal" {
    var game: Game = undefined;
    game.init(.white);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    const out = drive_event(&game, local_play(e2_e4));

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| {
                try testing.expectEqual(@as(u32, 1), prop.pending.sequence_number);
                try testing.expectEqual(Color.white, prop.pending.issued_by);
                try testing.expectEqual(@as(u8, 0), prop.retry_count);
                try testing.expectEqual(e2_e4, prop.pending.command.play.move);
                try testing.expectEqual(@as(?shared.PromotionPiece, null), prop.pending.command.play.promotion);
            },
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .send_proposal => |entry| {
            try testing.expectEqual(@as(u32, 1), entry.sequence_number);
            try testing.expectEqual(e2_e4, entry.command.play.move);
        },
        else => try testing.expect(false),
    }
}

test "Arm 1: illegal local_command emits local_rejected{illegal_move} and leaves state" {
    var game: Game = undefined;
    game.init(.white);

    // e4 is empty on the starting board.
    const empty_source = Move{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 4, .file = 4 } };
    const out = drive_event(&game, local_play(empty_source));

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .local_turn => {},
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .local_rejected => |rej| try testing.expectEqual(game_mod.LocalRejectionReason.illegal_move, rej.reason),
        else => try testing.expect(false),
    }
}

test "Arm 1: promotion-bound move transitions to awaiting_promotion_piece and prompts" {
    // White pawn on e7 about to push to e8 — preview_move returns .promotion with no
    // capture, so handle_local_play forks into the prompt branch instead of building a
    // proposal.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_pawn, .{ .rank = 6, .file = 4 });

    const e7_e8 = Move{ .from = .{ .rank = 6, .file = 4 }, .to = .{ .rank = 7, .file = 4 } };
    const out = drive_event(&game, local_play(e7_e8));

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .awaiting_promotion_piece => |held| {
                try testing.expectEqual(e7_e8, held.pending_move);
            },
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .prompt_for_promotion => |prompt| try testing.expectEqual(Color.white, prompt.color),
        else => try testing.expect(false),
    }
}

// ── Arm 7: local_promotion_choice in awaiting_promotion_piece ───────────────

test "Arm 7: promotion choice transitions to proposing and send_proposal carries piece" {
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_pawn, .{ .rank = 6, .file = 4 });

    const e7_e8 = Move{ .from = .{ .rank = 6, .file = 4 }, .to = .{ .rank = 7, .file = 4 } };
    _ = drive_event(&game, local_play(e7_e8));

    const out = drive_event(&game, .{ .local_promotion_choice = .{
        .piece = .knight,
        .think_time_ms = 0,
        .now_ms = 0,
    } });

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| {
                try testing.expectEqual(e7_e8, prop.pending.command.play.move);
                try testing.expectEqual(@as(?shared.PromotionPiece, .knight), prop.pending.command.play.promotion);
            },
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .send_proposal => |entry| try testing.expectEqual(@as(?shared.PromotionPiece, .knight), entry.command.play.promotion),
        else => try testing.expect(false),
    }
}

// ── Arm 2: remote_ack in proposing ──────────────────────────────────────────

test "Arm 2: matching remote_ack commits, transitions to remote_turn, emits render" {
    var game: Game = undefined;
    game.init(.white);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    _ = drive_event(&game, local_play(e2_e4));

    const out = drive_event(&game, .{ .remote_ack = 1 });

    try testing.expectEqual(Piece.empty, game.board.squares[1][4]);
    try testing.expectEqual(Piece.white_pawn, game.board.squares[3][4]);
    try testing.expectEqual(Color.black, game.turn);
    try testing.expectEqual(@as(u32, 2), game.expected_sequence_number);

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .remote_turn => {},
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expect(contains_tag(out, .render));
}

test "Arm 2: ack with non-matching seq bumps retry_count and emits request_resync" {
    var game: Game = undefined;
    game.init(.white);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    _ = drive_event(&game, local_play(e2_e4));

    const out = drive_event(&game, .{ .remote_ack = 99 });

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| {
                try testing.expectEqual(@as(u8, 1), prop.retry_count);
                try testing.expectEqual(@as(u32, 1), prop.pending.sequence_number);
            },
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    // Board untouched — commit didn't run.
    try testing.expectEqual(Piece.white_pawn, game.board.squares[1][4]);

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .request_resync => |req| {
            try testing.expectEqual(@as(u32, 1), req.last_known_sequence_number);
            try testing.expectEqual(@as(?game_mod.NackReason, null), req.peer_nack_reason);
        },
        else => try testing.expect(false),
    }
}

test "Arm 2: game-ending ack transitions to game_over and emits render + game_ended" {
    // Reuse the Qg7# fixture: white queen on g3 delivers Qg7# against black king on h8.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .white_queen, .{ .rank = 2, .file = 6 });
    test_util.place(&game.board, .white_knight, .{ .rank = 4, .file = 5 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .black_pawn, .{ .rank = 6, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };

    const qg3_g7 = Move{ .from = .{ .rank = 2, .file = 6 }, .to = .{ .rank = 6, .file = 6 } };
    _ = drive_event(&game, local_play(qg3_g7));

    const out = drive_event(&game, .{ .remote_ack = 1 });

    switch (game.state) {
        .game_over => |over| {
            try testing.expectEqual(GameResult.checkmate, over.result);
            try testing.expectEqual(@as(?Color, .white), over.winner);
        },
        else => try testing.expect(false),
    }

    try testing.expect(contains_tag(out, .render));
    try testing.expect(contains_tag(out, .game_ended));
}

// ── Arm 3: remote_nack in proposing ──────────────────────────────────────────

test "Arm 3: nack bumps retry_count and emits request_resync with peer_nack_reason set" {
    var game: Game = undefined;
    game.init(.white);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    _ = drive_event(&game, local_play(e2_e4));

    const out = drive_event(&game, .{ .remote_nack = .{
        .sequence_number = 1,
        .reason = .state_desync,
    } });

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| try testing.expectEqual(@as(u8, 1), prop.retry_count),
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .request_resync => |req| {
            try testing.expectEqual(@as(u32, 1), req.last_known_sequence_number);
            try testing.expectEqual(@as(?game_mod.NackReason, .state_desync), req.peer_nack_reason);
        },
        else => try testing.expect(false),
    }
}

test "Arm 2+3: ack mismatches and nacks share retry_count on the same proposal" {
    // 2 ack-mismatches followed by 1 nack should land retry_count at 3 (still under
    // MAX_RETRIES = 3, since the budget check is `< MAX_RETRIES` BEFORE the bump).
    var game: Game = undefined;
    game.init(.white);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    _ = drive_event(&game, local_play(e2_e4));

    _ = drive_event(&game, .{ .remote_ack = 999 });
    _ = drive_event(&game, .{ .remote_ack = 999 });
    _ = drive_event(&game, .{ .remote_nack = .{ .sequence_number = 1, .reason = .illegal_move } });

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| try testing.expectEqual(@as(u8, 3), prop.retry_count),
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }
}

// ── Arm 4: remote_proposal in remote_turn ───────────────────────────────────

test "Arm 4: legal remote_proposal commits, emits send_ack + render, transitions to local_turn" {
    // Init as black so local_color = black, state starts in remote_turn (white moves first).
    var game: Game = undefined;
    game.init(.black);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    const entry = LogEntry{
        .sequence_number = 1,
        .move_number = 1,
        .issued_by = .white,
        .command = .{ .play = .{ .move = e2_e4, .promotion = null } },
        .time_taken_ms = 0,
    };
    const out = drive_event(&game, .{ .remote_proposal = entry });

    try testing.expectEqual(Piece.empty, game.board.squares[1][4]);
    try testing.expectEqual(Piece.white_pawn, game.board.squares[3][4]);
    try testing.expectEqual(Color.black, game.turn);

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .local_turn => {},
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    var saw_ack = false;
    for (out.slice()) |effect| {
        if (effect == .send_ack) {
            try testing.expectEqual(@as(u32, 1), effect.send_ack);
            saw_ack = true;
        }
    }
    try testing.expect(saw_ack);
    try testing.expect(contains_tag(out, .render));
}

test "Arm 4: illegal remote_proposal emits send_nack{illegal_move}, state unchanged" {
    var game: Game = undefined;
    game.init(.black);

    // White pretending to move from an empty square (e4 is empty in the starting position).
    const phantom = Move{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 4, .file = 4 } };
    const entry = LogEntry{
        .sequence_number = 1,
        .move_number = 1,
        .issued_by = .white,
        .command = .{ .play = .{ .move = phantom, .promotion = null } },
        .time_taken_ms = 0,
    };
    const out = drive_event(&game, .{ .remote_proposal = entry });

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .remote_turn => {},
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .send_nack => |nack| {
            try testing.expectEqual(@as(u32, 1), nack.sequence_number);
            try testing.expectEqual(game_mod.NackReason.illegal_move, nack.reason);
        },
        else => try testing.expect(false),
    }
}

test "Arm 4: remote_proposal with seq mismatch emits send_nack{state_desync}" {
    var game: Game = undefined;
    game.init(.black);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    const entry = LogEntry{
        // expected_sequence_number is 1, but the proposal claims 5 — desync.
        .sequence_number = 5,
        .move_number = 1,
        .issued_by = .white,
        .command = .{ .play = .{ .move = e2_e4, .promotion = null } },
        .time_taken_ms = 0,
    };
    const out = drive_event(&game, .{ .remote_proposal = entry });

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .send_nack => |nack| {
            try testing.expectEqual(@as(u32, 5), nack.sequence_number);
            try testing.expectEqual(game_mod.NackReason.state_desync, nack.reason);
        },
        else => try testing.expect(false),
    }
}

// ── Arm 5: local_command while proposing ────────────────────────────────────

test "Arm 5: local_command in proposing emits local_rejected{already_proposing}" {
    var game: Game = undefined;
    game.init(.white);

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    _ = drive_event(&game, local_play(e2_e4));

    const d2_d4 = Move{ .from = .{ .rank = 1, .file = 3 }, .to = .{ .rank = 3, .file = 3 } };
    const out = drive_event(&game, local_play(d2_d4));

    // State unchanged — still proposing the e2-e4.
    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| try testing.expectEqual(e2_e4, prop.pending.command.play.move),
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .local_rejected => |rej| try testing.expectEqual(game_mod.LocalRejectionReason.already_proposing, rej.reason),
        else => try testing.expect(false),
    }
}

// ── Arm 6: rejection matrix samples ─────────────────────────────────────────

test "Arm 6: local_command in remote_turn emits local_rejected{out_of_turn}" {
    var game: Game = undefined;
    game.init(.black); // black local → state starts in remote_turn

    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    const out = drive_event(&game, local_play(e2_e4));

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .local_rejected => |rej| try testing.expectEqual(game_mod.LocalRejectionReason.out_of_turn, rej.reason),
        else => try testing.expect(false),
    }
}

test "Arm 6: local_command in game_over emits local_rejected{game_ended}" {
    // Drive a game to checkmate first, then issue another local_command.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .white_queen, .{ .rank = 2, .file = 6 });
    test_util.place(&game.board, .white_knight, .{ .rank = 4, .file = 5 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .black_pawn, .{ .rank = 6, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };

    const qg3_g7 = Move{ .from = .{ .rank = 2, .file = 6 }, .to = .{ .rank = 6, .file = 6 } };
    _ = drive_event(&game, local_play(qg3_g7));
    _ = drive_event(&game, .{ .remote_ack = 1 });

    // State is now game_over.
    const followup = Move{ .from = .{ .rank = 0, .file = 0 }, .to = .{ .rank = 0, .file = 1 } };
    const out = drive_event(&game, local_play(followup));

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .local_rejected => |rej| try testing.expectEqual(game_mod.LocalRejectionReason.game_ended, rej.reason),
        else => try testing.expect(false),
    }
}

test "Arm 6: local_promotion_choice in local_turn emits local_rejected{unsolicited_promotion_choice}" {
    var game: Game = undefined;
    game.init(.white);

    const out = drive_event(&game, .{ .local_promotion_choice = .{
        .piece = .queen,
        .think_time_ms = 0,
        .now_ms = 0,
    } });

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .local_rejected => |rej| try testing.expectEqual(game_mod.LocalRejectionReason.unsolicited_promotion_choice, rej.reason),
        else => try testing.expect(false),
    }
}

// ── Top-level retry counter ─────────────────────────────────────────────────

test "top-level retry: unsolicited remote_ack in local_turn bumps counter and emits request_resync" {
    var game: Game = undefined;
    game.init(.white);

    try testing.expectEqual(@as(u8, 0), game.unexpected_event_count);

    const out = drive_event(&game, .{ .remote_ack = 7 });

    try testing.expectEqual(@as(u8, 1), game.unexpected_event_count);

    // State unchanged — still local_turn.
    switch (game.state) {
        .playing => |playing| switch (playing) {
            .local_turn => {},
            else => try testing.expect(false),
        },
        else => try testing.expect(false),
    }

    try testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .request_resync => |req| {
            try testing.expectEqual(@as(u32, 1), req.last_known_sequence_number);
            try testing.expectEqual(@as(?game_mod.NackReason, null), req.peer_nack_reason);
        },
        else => try testing.expect(false),
    }
}

test "top-level retry: counter resets when an expected event lands" {
    var game: Game = undefined;
    game.init(.white);

    // Two unsolicited remote_acks while in local_turn → counter at 2.
    _ = drive_event(&game, .{ .remote_ack = 7 });
    _ = drive_event(&game, .{ .remote_ack = 8 });
    try testing.expectEqual(@as(u8, 2), game.unexpected_event_count);

    // Now a real local_command that lands a proposal — submit_proposal resets the counter.
    const e2_e4 = Move{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } };
    _ = drive_event(&game, local_play(e2_e4));

    try testing.expectEqual(@as(u8, 0), game.unexpected_event_count);
}

// Note: the panic paths (Arm 2/3 budget exhaustion, top-level retry exhaustion at the 4th
// unsolicited event) are not asserted in this suite — Zig 0.16 does not provide a
// panic-recovery helper for tests. Those paths should be exercised manually by removing
// the `< MAX_RETRIES` / `>= MAX_UNEXPECTED_EVENTS` guards and watching the panic fire.
