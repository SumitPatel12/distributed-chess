//! Test-only helpers that drive `Game.tick` through a complete move flow in one call.
//! `apply_move` dispatches on the current playing state — local turns go through
//! `local_command` + auto-`remote_ack`, remote turns go through a synthesized `remote_proposal`
//! whose `send_ack` is implicit in the tick. Tests get to assert on post-commit board state
//! without scripting every protocol step. For protocol-level coverage (intermediate proposing
//! state, retry budget, nack paths) see game_protocol_tests.zig.

const std = @import("std");
const game_mod = @import("game.zig");
const shared = @import("shared.zig");
const Game = game_mod.Game;
const GameEvent = game_mod.GameEvent;
const GameEffect = game_mod.GameEffect;
const LogEntry = game_mod.LogEntry;
const Move = shared.Move;
const PromotionPiece = shared.PromotionPiece;
const BoundedArray = @import("bounded_array.zig").BoundedArray;

pub const ApplyMoveError = error{
    IllegalMove,
    OutOfTurn,
    AlreadyProposing,
    GameEnded,
    AwaitingPromotionPiece,
    UnsolicitedPromotionChoice,
};

/// Drives a non-promoting move through `tick`. Dispatches on state: `local_turn` runs the
/// `local_command` + auto-`remote_ack` flow; `remote_turn` synthesizes a `remote_proposal`
/// (Arm 4) so multi-color tests can keep playing on a single game without re-binding the
/// local color. Promoting moves panic — use `apply_move_with_promotion`.
pub fn apply_move(game: *Game, move: Move) ApplyMoveError!void {
    switch (game.state) {
        .playing => |playing| switch (playing) {
            .local_turn => return apply_local_move(game, move),
            .remote_turn => return apply_remote_move(game, move),
            .proposing => return error.AlreadyProposing,
            .awaiting_promotion_piece => return error.AwaitingPromotionPiece,
            .awaiting_draw_response => @panic("apply_move: awaiting_draw_response not supported by helper"),
        },
        .paused_disconnected, .game_over => return error.GameEnded,
    }
}

fn apply_local_move(game: *Game, move: Move) ApplyMoveError!void {
    var out: BoundedArray(GameEffect, Game.MAX_EFFECTS) = .{};

    game.tick(.{ .local_command = .{
        .command = .{ .play = .{ .move = move, .promotion = null } },
        .think_time_ms = 0,
        .now_ms = 0,
    } }, &out);

    var send_proposal_seq: ?u32 = null;
    for (out.slice()) |effect| {
        switch (effect) {
            .local_rejected => |rej| return map_rejection_reason(rej.reason),
            .send_proposal => |entry| send_proposal_seq = entry.sequence_number,
            .prompt_for_promotion => @panic("apply_move: move requires promotion; use apply_move_with_promotion instead"),
            else => {},
        }
    }
    const seq = send_proposal_seq orelse @panic("apply_move: no send_proposal effect emitted");

    out = .{};
    game.tick(.{ .remote_ack = seq }, &out);
}

fn apply_remote_move(game: *Game, move: Move) ApplyMoveError!void {
    var out: BoundedArray(GameEffect, Game.MAX_EFFECTS) = .{};

    const entry = LogEntry{
        .sequence_number = game.expected_sequence_number,
        .move_number = game.fullmove_number,
        .issued_by = game.turn,
        .command = .{ .play = .{ .move = move, .promotion = null } },
        .time_taken_ms = 0,
    };
    game.tick(.{ .remote_proposal = entry }, &out);

    for (out.slice()) |effect| {
        switch (effect) {
            .send_nack => |nack| return switch (nack.reason) {
                .illegal_move => error.IllegalMove,
                .out_of_turn => error.OutOfTurn,
                .state_desync => @panic("apply_move: remote_proposal seq desync — helper built the entry, this is a bug"),
            },
            else => {},
        }
    }
}

/// Drives a promoting local move through `tick`: issues the `local_command` (with
/// `promotion = null` so tick prompts), submits the chosen piece, then auto-acks the
/// resulting proposal. Only valid in `local_turn`. Non-promoting moves panic.
pub fn apply_move_with_promotion(
    game: *Game,
    move: Move,
    piece: PromotionPiece,
) ApplyMoveError!void {
    var out: BoundedArray(GameEffect, Game.MAX_EFFECTS) = .{};

    game.tick(.{ .local_command = .{
        .command = .{ .play = .{ .move = move, .promotion = null } },
        .think_time_ms = 0,
        .now_ms = 0,
    } }, &out);

    var saw_prompt = false;
    for (out.slice()) |effect| {
        switch (effect) {
            .local_rejected => |rej| return map_rejection_reason(rej.reason),
            .prompt_for_promotion => saw_prompt = true,
            .send_proposal => @panic("apply_move_with_promotion: move did not require promotion; use apply_move"),
            else => {},
        }
    }
    if (!saw_prompt) @panic("apply_move_with_promotion: expected prompt_for_promotion effect");

    out = .{};
    game.tick(.{ .local_promotion_choice = .{
        .piece = piece,
        .think_time_ms = 0,
        .now_ms = 0,
    } }, &out);

    var send_proposal_seq: ?u32 = null;
    for (out.slice()) |effect| {
        switch (effect) {
            .send_proposal => |entry| send_proposal_seq = entry.sequence_number,
            else => {},
        }
    }
    const seq = send_proposal_seq orelse @panic("apply_move_with_promotion: no send_proposal after promotion choice");

    out = .{};
    game.tick(.{ .remote_ack = seq }, &out);
}

fn map_rejection_reason(reason: game_mod.LocalRejectionReason) ApplyMoveError {
    return switch (reason) {
        .illegal_move => error.IllegalMove,
        .out_of_turn => error.OutOfTurn,
        .already_proposing => error.AlreadyProposing,
        .game_ended => error.GameEnded,
        .awaiting_promotion_piece => error.AwaitingPromotionPiece,
        .unsolicited_promotion_choice => error.UnsolicitedPromotionChoice,
    };
}
