//! The top level game structure that keeps track of the complete game state, including players,
//! board, game result, and any other things related to the game.

const std = @import("std");
const board_mod = @import("board.zig");
const BoundedArray = @import("bounded_array.zig").BoundedArray;
const Board = board_mod.Board;
const shared = @import("shared.zig");
const Color = shared.Color;
const Move = shared.Move;
const Position = shared.Position;
const CastlingRights = shared.CastlingRights;
const PromotionPiece = shared.PromotionPiece;
const Piece = board_mod.Piece;
const rules_engine = @import("rule_engine/rules.zig");
const MoveEffect = rules_engine.MoveEffect;
const zobrist = @import("rule_engine/zobrist.zig");

pub const GameResult = enum {
    /// One of the players won by checkmating.
    checkmate,

    /// The position resulted in a stalemate.
    stalemate,

    /// One of the players resigned.
    resignation,

    /// A player proposed a draw and the opponent accepted.
    draw_by_agreement,

    /// Represents a draw for when no player has moved a pawn or has captured any piece for 50 full
    /// moves
    draw_fifty_moves,

    /// Represents an automatic draw when 75 full moves go on without any pawn moves or capture.
    draw_seventy_five_moves,

    /// Draw by three fold repetition, i.e. when the same position is reached thrice.
    draw_threefold_repetition,

    /// Draw due to insufficient material. Automatically applied when the game detects insufficient
    /// materials on the board.
    draw_insufficient_material,

    /// Flag-fall: one player's clock hit zero. The connected player wins.
    timeout,

    /// Awards the player a win if the opponent disconnected and didn't reconnect for a certain
    /// period of time.
    disconnect,

    /// Both players disconnected and failed to reconnect, we declare that as a draw.
    disconnect_both,
};

/// Playing represents either local or opponents turn, depending on whose turn it is.
pub const Playing = union(enum) {
    local_turn,
    remote_turn,
    proposing: struct {
        pending: LogEntry,
        proposed_at_ms: u32,
        retry_count: u8 = 0,
    },

    /// Awaiting the users input for the selecting the pawns promotion piece.
    awaiting_promotion_piece: struct {
        pending_move: Move,
        issued_at_ms: u32,
    },

    /// A draw has been offered and we're waiting on the other side to accept/decline.
    /// `offered_by` is the color that sent the offer — either side can be the offerer
    /// (both replicas enter this state on the same command, differing only in local_color).
    /// Any move by the offerer implicitly withdraws the offer; any move by the other side
    /// implicitly declines.
    awaiting_draw_response: struct { offered_by: Color },
};

pub const PausedDisconnected = struct {
    was: Playing,
    deadline_ms: u32,
};

pub const GameOver = struct {
    result: GameResult,
    winner: ?Color,
    final_sequence_number: u32,
};

const GameState = union(enum) {
    playing: Playing,

    paused_disconnected: PausedDisconnected,

    /// Game is over with the result stored in the enum. `final_sequence_number` pins the exact RSM
    /// command that ended the game — used for rematch setup (start from final_sequence_number + 1), for
    /// persistence, and for disambiguating commands that share a move_number (e.g. a move
    /// and a resignation both issued during move 30 are distinct commands, distinct seqs).
    game_over: GameOver,
};

pub const DrawClaim = enum {
    fifty_moves,
    threefold_repetition,
};

pub const GameCommand = union(enum) {
    play: struct { move: Move, promotion: ?PromotionPiece },
    resign,
    offer_draw,
    accept_draw,
    decline_draw,
    claim_draw: DrawClaim,
};

/// For the RSM to keep in sync. Sent to the opponent while making a move.
pub const LogEntry = struct {
    /// Monotonically increasing sequence number for ordering.
    sequence_number: u32,

    move_number: u16,

    command: GameCommand,

    issued_by: Color,

    // We don't send the original clock times because it would be unnecessary in my opinion, what we
    // measure is how much time was spent on a move and the clock is decremented based off of that
    // metric, when you think like that sending the delta makes more sense.
    //
    /// Duration the player spent on this move.
    time_taken_ms: u32,
};

pub const LocalRejectionReason = enum {
    illegal_move,
    out_of_turn,
    already_proposing,
    game_ended,
    awaiting_promotion_piece,

    /// Represents a rejection when a promotion piece choice arrives outside of
    /// awaiting_promotion_piece.
    unsolicited_promotion_choice,
};

pub const NackReason = enum {
    illegal_move,
    out_of_turn,

    /// Receiver's state diverged from sender's — the command was valid on the sender's view
    /// but not on the receiver's. Triggers the resync recovery path (request_resync effect,
    /// transition to paused_disconnected). Not a bug — a distributed-systems runtime condition.
    state_desync,
};

pub const Nack = struct {
    sequence_number: u32,
    reason: NackReason,
};

pub const WireMessage = union(enum) {
    propose: LogEntry,

    /// The sequence number being acknowledged
    ack: u32,

    /// Sequence number being rejected, along with the reason for doing so.
    nack: Nack,
};

pub const GameEvent = union(enum) {
    local_command: struct {
        command: GameCommand,

        /// Amount of time player took to make this move.
        think_time_ms: u32,

        /// The Loop's clock at dispatch. Used when proposing a move.
        now_ms: u32,
    },

    /// The local player has chosen a promotion piece for a pawn.
    local_promotion_choice: struct {
        piece: PromotionPiece,
        think_time_ms: u32,
        now_ms: u32,
    },

    remote_proposal: LogEntry,

    /// The sequence number of the log entry/move that's being acknowledged by the opponent.
    remote_ack: u32,

    /// Sequence number and Nack reason from the opponent for rejecting the move.
    remote_nack: Nack,

    /// For timed matches represents a clock tick, the unit of which will default to second.
    clock_tick,

    peer_disconnected,
    peer_reconnected,
    disconnect_timer_expired,
    proposal_timeout,
};

pub const GameEffect = union(enum) {
    send_proposal: LogEntry,
    send_ack: u32,
    send_nack: Nack,
    local_rejected: struct { reason: LocalRejectionReason },
    render,
    game_ended: GameResult,
    prompt_for_promotion: struct { color: Color },

    request_resync: struct {
        last_known_sequence_number: u32,
        peer_nack_reason: ?NackReason,
    },

    /// Starts the auto timer when the opponent disconnects. The current player is directly awarded
    /// the win if the opponent fails to reconnect within a certain time period.
    start_disconnect_timer: u32,
};

/// Represents the game being played. Holds the complete data of the game including players move
/// history, game state, the log for the RSM.
pub const Game = struct {
    board: Board,

    turn: Color,

    // I bounced between player_color and local_color and local_color seems the better option. After
    // sketching out the rule engine and all it was getting quite easy to conflate the name
    // `player_color` with some other things.
    /// The color of the local/process owning player.
    local_color: Color,

    // Description copied with care from the internet :p
    /// A full move consists of two consecutive turns—one by White and one by Black—whereas a
    /// half-move (or "ply") refers to a single turn by one player.
    fullmove_number: u16,

    /// Counts the number of half moves since the last capture or pawn move.
    /// Required when one of the players want's to propose/claim a draw under the 50 move rule.
    halfmove_clock: u16,

    state: GameState,

    /// Pieces white has captured from black. Bounded to 15 since white can capture at most 15 of
    /// black's 16 pieces — the king is never captured.
    captures_by_white: BoundedArray(Piece, 15),

    /// Pieces black has captured from white. Same bound and reasoning as captures_by_white.
    captures_by_black: BoundedArray(Piece, 15),

    /// Position has that tracks if the position has been repeated, required for three-fold
    /// repetition draw rule.
    position_hashes: BoundedArray(u64, MAX_LOG),

    expected_sequence_number: u32,

    castling_rights: CastlingRights,

    /// The square an opposing pawn could capture to, if the last move was a two-square pawn
    /// advance. Cleared on every move that doesn't create a new en-passant target.
    en_passant_square: ?Position,

    /// Keeps track of each command fired. Includes the moves, draw offers, etc.
    /// Can be replayed to get to the same state. Will be used to get an observer up to speed by
    /// sending them the logs.
    command_log: BoundedArray(LogEntry, MAX_LOG),

    /// Keeps track of the number of unexpected events received, panics when they reach the threshold
    /// of `MAX_UNEXPECTED_EVENTS` for a given iteration.
    unexpected_event_count: u8 = 0,

    /// Upper bound on effects emitted by a single tick(). 16 leaves headroom for paths that
    /// stack multiple effects (e.g. send_ack + apply + render + game_ended + start_*_timer).
    pub const MAX_EFFECTS = 16;

    /// Upper bound on command-log and position-hash entries. 512 is ample for a real chess
    /// game (longest practical games run ~300 half-moves; the fifty-move rule caps growth).
    const MAX_LOG = 512;

    /// Shared cap on resync attempts for a single proposal — counts any mix of ack-seq mismatches
    /// and peer nacks. Past this we panic; recovery has failed enough times that staying live risks
    /// compounding the divergence.
    const MAX_RETRIES: u8 = 3;

    const MAX_UNEXPECTED_EVENTS: u8 = 3;

    pub fn initial_state(color: Color) GameState {
        return switch (color) {
            .white => GameState{ .playing = .local_turn },
            .black => GameState{ .playing = .remote_turn },
        };
    }

    pub fn init(self: *Game, local_color: Color) void {
        self.* = .{
            .board = undefined,
            .state = initial_state(local_color),
            .turn = .white,
            .halfmove_clock = 0,
            .fullmove_number = 1,
            .local_color = local_color,
            .captures_by_white = .{},
            .captures_by_black = .{},
            .position_hashes = .{},
            .expected_sequence_number = 1,
            .castling_rights = .{},
            .en_passant_square = null,
            .command_log = .{},
            .unexpected_event_count = 0,
        };
        self.board.init();
        self.position_hashes.append_assume_capacity(zobrist.INITIAL_BOARD_ZOBRIST_HASH);
    }

    fn handle_unexpected_event(self: *Game, out: *BoundedArray(GameEffect, MAX_EFFECTS)) void {
        if (self.unexpected_event_count >= MAX_UNEXPECTED_EVENTS) {
            @panic("too many unexpected events");
        }

        self.unexpected_event_count += 1;
        out.append_assume_capacity(.{
            .request_resync = .{
                .last_known_sequence_number = self.expected_sequence_number,
                .peer_nack_reason = null,
            },
        });
    }

    /// The state machine with side effects. It reads the game event, mutates the state of the board
    /// and tracked state and returns the side-effects.
    pub fn tick(self: *Game, event: GameEvent, out: *BoundedArray(GameEffect, MAX_EFFECTS)) void {
        std.debug.assert(self.expected_sequence_number >= 1);
        std.debug.assert(self.position_hashes.len <= MAX_LOG);

        switch (self.state) {
            .playing => |playing| switch (playing) {
                .local_turn => switch (event) {
                    .local_command => |payload| switch (payload.command) {
                        .play => |play| self.handle_local_play(play, payload.think_time_ms, payload.now_ms, out),
                        else => @panic("non-play GameCommand variants not yet implemented in tick"),
                    },
                    .local_promotion_choice => {
                        out.append_assume_capacity(.{
                            .local_rejected = .{
                                .reason = .unsolicited_promotion_choice,
                            },
                        });
                    },
                    .remote_ack, .remote_nack => self.handle_unexpected_event(out),
                    // TODO: Replace with send_nack{state_desync} once DEC-011 (simultaneous-proposal tie-break) lands.
                    .remote_proposal => @panic("simultaneous proposal — tie-break (DEC-011) not yet implemented"),
                    .clock_tick => {
                        // TODO: Decrement the local player's clock; transition to game_over{timeout} on zero.
                    },
                    .peer_disconnected => {
                        // TODO: Snapshot current state into paused_disconnected and start the disconnect timer.
                    },
                    .peer_reconnected, .disconnect_timer_expired, .proposal_timeout => {
                        // No-op: these only fire in paused_disconnected / proposing.
                    },
                },
                .remote_turn => switch (event) {
                    .remote_proposal => |entry| self.handle_remote_proposal(entry, out),
                    .local_command => {
                        out.append_assume_capacity(.{
                            .local_rejected = .{
                                .reason = .out_of_turn,
                            },
                        });
                    },
                    .local_promotion_choice => {
                        out.append_assume_capacity(.{
                            .local_rejected = .{
                                .reason = .unsolicited_promotion_choice,
                            },
                        });
                    },
                    .remote_ack, .remote_nack => {
                        self.handle_unexpected_event(out);
                    },
                    .clock_tick => {
                        // TODO: Decrement the remote player's clock; transition to game_over{timeout} on zero.
                    },
                    .peer_disconnected => {
                        // TODO: Snapshot current state into paused_disconnected and start the disconnect timer.
                    },
                    .peer_reconnected, .disconnect_timer_expired, .proposal_timeout => {
                        // No-op: these only fire in paused_disconnected / proposing.
                    },
                },
                .proposing => |proposal| switch (event) {
                    .remote_ack => |acked_sequence_number| self.handle_remote_ack(proposal, acked_sequence_number, out),
                    .remote_nack => |nack| self.handle_remote_nack(proposal, nack, out),
                    .local_command => {
                        out.append_assume_capacity(.{
                            .local_rejected = .{
                                .reason = .already_proposing,
                            },
                        });
                    },
                    .local_promotion_choice => {
                        out.append_assume_capacity(.{
                            .local_rejected = .{
                                .reason = .unsolicited_promotion_choice,
                            },
                        });
                    },
                    // TODO: Replace with send_nack{state_desync} once DEC-011 (simultaneous-proposal tie-break) lands.
                    .remote_proposal => @panic("simultaneous proposal — tie-break (DEC-011) not yet implemented"),
                    .proposal_timeout => {
                        // TODO: Trigger retry via request_resync, or panic when the retry budget is exhausted.
                    },
                    .clock_tick => {
                        // TODO: Decrement the local player's clock; transition to game_over{timeout} on zero.
                    },
                    .peer_disconnected => {
                        // TODO: Snapshot current state into paused_disconnected and start the disconnect timer.
                    },
                    .peer_reconnected, .disconnect_timer_expired => {
                        // No-op: these only fire in paused_disconnected.
                    },
                },
                .awaiting_promotion_piece => |held| switch (event) {
                    .local_promotion_choice => |choice| self.handle_promotion_choice(held, choice, out),
                    .local_command => {
                        out.append_assume_capacity(.{
                            .local_rejected = .{
                                .reason = .awaiting_promotion_piece,
                            },
                        });
                    },
                    .remote_ack, .remote_nack => {
                        self.handle_unexpected_event(out);
                    },
                    // TODO: Replace with send_nack{state_desync} once DEC-011 (simultaneous-proposal tie-break) lands.
                    .remote_proposal => @panic("simultaneous proposal — tie-break (DEC-011) not yet implemented"),
                    .clock_tick => {
                        // TODO: Decrement the local player's clock; transition to game_over{timeout} on zero.
                    },
                    .peer_disconnected => {
                        // TODO: Snapshot current state into paused_disconnected and start the disconnect timer.
                    },
                    .peer_reconnected, .disconnect_timer_expired, .proposal_timeout => {
                        // No-op: these only fire in paused_disconnected / proposing.
                    },
                },
                .awaiting_draw_response => switch (event) {
                    .local_command, .local_promotion_choice => {
                        // TODO: A move from the offerer withdraws the offer; from the other side declines it.
                    },
                    .remote_proposal => {
                        // TODO: Opponent's move implicitly accepts/declines the offer per DEC-***.
                    },
                    .remote_ack, .remote_nack => {
                        // TODO: Forward to the resync layer — these can arrive while waiting for a draw response.
                    },
                    .clock_tick => {
                        // TODO: Decrement clocks; offer lapses on timeout.
                    },
                    .peer_disconnected => {
                        // TODO: Snapshot current state into paused_disconnected and start the disconnect timer.
                    },
                    .peer_reconnected, .disconnect_timer_expired, .proposal_timeout => {
                        // No-op: these only fire in paused_disconnected / proposing.
                    },
                },
            },
            .paused_disconnected => switch (event) {
                .local_command, .local_promotion_choice => {
                    out.append_assume_capacity(.{
                        .local_rejected = .{ .reason = .game_ended },
                    });
                },
                .peer_reconnected => {
                    // TODO: Restore the snapshotted `was` state and cancel the disconnect timer.
                },
                .disconnect_timer_expired => {
                    // TODO: Award the win to the connected player — transition to game_over{disconnect}.
                },
                .remote_proposal, .remote_ack, .remote_nack => {
                    // TODO: Buffer or forward to the resync layer once we re-emerge from paused_disconnected.
                },
                .clock_tick, .peer_disconnected, .proposal_timeout => {
                    // No-op: clocks are paused, peer can't disconnect twice, no proposal pending.
                },
            },
            .game_over => switch (event) {
                .local_command, .local_promotion_choice => {
                    out.append_assume_capacity(.{
                        .local_rejected = .{ .reason = .game_ended },
                    });
                },
                .remote_ack, .remote_nack, .remote_proposal => self.handle_unexpected_event(out),
                .clock_tick, .peer_disconnected, .peer_reconnected, .disconnect_timer_expired, .proposal_timeout => {
                    // No-op: game's over, nothing to do.
                },
            },
        }
    }

    fn handle_local_play(
        self: *Game,
        play: @FieldType(GameCommand, "play"),
        think_time_ms: u32,
        now_ms: u32,
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        const move_effect = rules_engine.preview_move(
            &self.board,
            self.turn,
            play.move,
            self.castling_rights,
            self.en_passant_square,
        ) catch |err| switch (err) {
            error.IllegalMove => {
                out.append_assume_capacity(.{ .local_rejected = .{ .reason = .illegal_move } });
                return;
            },
        };

        if (move_effect == .promotion and play.promotion == null) {
            self.state = .{
                .playing = .{
                    .awaiting_promotion_piece = .{
                        .pending_move = play.move,
                        .issued_at_ms = now_ms,
                    },
                },
            };
            out.append_assume_capacity(.{ .prompt_for_promotion = .{ .color = self.local_color } });
            self.unexpected_event_count = 0;
            return;
        }

        const log_entry = LogEntry{
            .sequence_number = self.expected_sequence_number,
            .move_number = self.fullmove_number,
            .issued_by = self.local_color,
            .command = .{ .play = play },
            .time_taken_ms = think_time_ms,
        };
        self.submit_proposal(log_entry, now_ms, out);
    }

    fn handle_promotion_choice(
        self: *Game,
        held: @FieldType(Playing, "awaiting_promotion_piece"),
        choice: @FieldType(GameEvent, "local_promotion_choice"),
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        const log_entry = LogEntry{
            .sequence_number = self.expected_sequence_number,
            .move_number = self.fullmove_number,
            .issued_by = self.local_color,
            .command = .{
                .play = .{
                    .move = held.pending_move,
                    .promotion = choice.piece,
                },
            },
            .time_taken_ms = choice.think_time_ms,
        };
        self.submit_proposal(log_entry, held.issued_at_ms, out);
    }

    /// Arm: `playing.proposing × remote_ack`. On matching seq, re-derives the MoveEffect on
    /// the (still unchanged) local board, commits, and transitions to `remote_turn` (or
    /// `game_over`). On mismatched seq the proposal is alive but the peer's view drifted —
    /// bump the retry counter and request a resync, or panic if the budget is exhausted.
    fn handle_remote_ack(
        self: *Game,
        proposal: @FieldType(Playing, "proposing"),
        acked_sequence_number: u32,
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        if (acked_sequence_number != proposal.pending.sequence_number) {
            if (proposal.retry_count < MAX_RETRIES) {
                self.request_resync(proposal, null, out);
            } else {
                @panic("desync recovery exhausted: ack seq mismatch");
            }
            return;
        }

        // Pre-issue validation already accepted this move on this exact board, so preview
        // can't refuse it now — any error here means a real invariant break, not a
        // recoverable rejection.
        const move_effect = rules_engine.preview_move(
            &self.board,
            self.turn,
            proposal.pending.command.play.move,
            self.castling_rights,
            self.en_passant_square,
        ) catch unreachable;

        const verdict = self.commit(proposal.pending, move_effect);

        if (verdict) |game_over| {
            self.state = .{ .game_over = game_over };
            out.append_assume_capacity(.render);
            out.append_assume_capacity(.{ .game_ended = game_over.result });
        } else {
            self.state = .{ .playing = .remote_turn };
            out.append_assume_capacity(.render);
        }
        self.unexpected_event_count = 0;
    }

    /// Arm: `playing.proposing × remote_nack`. Any nack is a divergence signal regardless of
    /// `nack.sequence_number` — peer rejected the proposal so our state is suspect. Reuse Arm 2's
    /// shared retry budget (any mix of seq mismatches and nacks counts toward the same
    /// MAX_RETRIES cap), pass the peer's reason through for the wire layer to pick a
    /// recovery strategy, or panic when the budget is exhausted.
    fn handle_remote_nack(
        self: *Game,
        proposal: @FieldType(Playing, "proposing"),
        nack: @FieldType(GameEvent, "remote_nack"),
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        if (proposal.retry_count < MAX_RETRIES) {
            self.request_resync(proposal, nack.reason, out);
        } else {
            @panic("desync recovery exhausted: peer nack");
        }
    }

    /// Arm: `playing.remote_turn × remote_proposal`. Receive-side mirror of Arms 1+2:
    /// validate seq, validate via the rule engine, commit, then ack and transition to
    /// `local_turn` (or `game_over`). Commit deliberately runs BEFORE `send_ack` — local
    /// state must be consistent before the peer is told their move landed; otherwise a
    /// crash between ack and apply would leave the peer thinking we're ahead when we
    /// aren't.
    fn handle_remote_proposal(
        self: *Game,
        entry: LogEntry,
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        if (entry.sequence_number != self.expected_sequence_number) {
            out.append_assume_capacity(.{
                .send_nack = .{
                    .sequence_number = entry.sequence_number,
                    .reason = .state_desync,
                },
            });
            return;
        }

        const move_effect = rules_engine.preview_move(
            &self.board,
            self.turn,
            entry.command.play.move,
            self.castling_rights,
            self.en_passant_square,
        ) catch |err| switch (err) {
            error.IllegalMove => {
                out.append_assume_capacity(.{
                    .send_nack = .{
                        .sequence_number = entry.sequence_number,
                        .reason = .illegal_move,
                    },
                });
                return;
            },
        };

        const verdict = self.commit(entry, move_effect);

        out.append_assume_capacity(.{ .send_ack = entry.sequence_number });

        if (verdict) |game_over| {
            self.state = .{ .game_over = game_over };
            out.append_assume_capacity(.render);
            out.append_assume_capacity(.{ .game_ended = game_over.result });
        } else {
            self.state = .{ .playing = .local_turn };
            out.append_assume_capacity(.render);
        }
        self.unexpected_event_count = 0;
    }

    /// Bumps the proposal's `retry_count` and emits a `request_resync` effect carrying the
    /// peer's nack reason (null when triggered by an ack-seq mismatch instead of a nack).
    /// Shared between Arm 2 (ack mismatch) and Arm 3 (peer nack) — they fund the same
    /// retry budget.
    fn request_resync(
        self: *Game,
        proposal: @FieldType(Playing, "proposing"),
        peer_nack_reason: ?NackReason,
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        self.state = .{ .playing = .{ .proposing = .{
            .pending = proposal.pending,
            .proposed_at_ms = proposal.proposed_at_ms,
            .retry_count = proposal.retry_count + 1,
        } } };
        out.append_assume_capacity(.{ .request_resync = .{
            .last_known_sequence_number = proposal.pending.sequence_number,
            .peer_nack_reason = peer_nack_reason,
        } });
    }

    /// Transitions to `playing.proposing` with the given entry and emits the `send_proposal`
    /// effect.
    fn submit_proposal(
        self: *Game,
        entry: LogEntry,
        proposed_at_ms: u32,
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        self.state = .{
            .playing = .{
                .proposing = .{
                    .pending = entry,
                    .proposed_at_ms = proposed_at_ms,
                    .retry_count = 0,
                },
            },
        };
        out.append_assume_capacity(.{ .send_proposal = entry });
        self.unexpected_event_count = 0;
    }

    /// Commits the effects of the move to the board, and updates the relevant fields.
    /// In case of a terminal state returns an optional GameOver struct. It's the caller's
    /// responsibility to update the game state to represent the terminal state.
    fn commit(self: *Game, log_entry: LogEntry, move_effect: MoveEffect) ?GameOver {
        const move = switch (log_entry.command) {
            .play => |play| play.move,
            else => unreachable,
        };

        // Snapshot the mover's piece identity BEFORE `board.move` below mutates the source square
        // — the 50-move clock further down needs to know whether this was a pawn move.
        const moving_piece = self.board.squares[move.from.rank][move.from.file];
        const is_pawn_move = moving_piece == .white_pawn or moving_piece == .black_pawn;

        self.castling_rights = rules_engine.castling_rights_after(
            &self.board,
            self.turn,
            move,
            move_effect,
            self.castling_rights,
        );
        self.board.move(move.from, move.to);

        // En-passant target is a one-ply window: only valid immediately after a double push.
        // Reset here; the pawn_double_push arm below re-sets it to the square the pawn passed over.
        self.en_passant_square = null;

        switch (move_effect) {
            .capture => |captured_piece| self.append_captured_piece(captured_piece),
            .promotion => |promotion| {
                if (promotion.capture) |captured_piece| {
                    self.append_captured_piece(captured_piece);
                }

                const promotion_piece = log_entry.command.play.promotion.?;
                const is_dark_square = (@as(u4, move.to.rank) + @as(u4, move.to.file)) % 2 == 0;
                self.board.squares[move.to.rank][move.to.file] = switch (self.turn) {
                    .white => switch (promotion_piece) {
                        .queen => .white_queen,
                        .rook => .white_rook,
                        .knight => .white_knight,
                        .bishop => if (is_dark_square) .white_bishop_dark else .white_bishop_light,
                    },
                    .black => switch (promotion_piece) {
                        .queen => .black_queen,
                        .rook => .black_rook,
                        .knight => .black_knight,
                        .bishop => if (is_dark_square) .black_bishop_dark else .black_bishop_light,
                    },
                };
            },
            .en_passant => |ep| {
                const captured_pawn: Piece = switch (self.turn) {
                    .white => .black_pawn,
                    .black => .white_pawn,
                };
                self.append_captured_piece(captured_pawn);
                self.board.clear(ep.captured_pawn_at);
            },
            .castling => |castling| {
                self.board.move(castling.rook_from, castling.rook_to);
            },
            .pawn_double_push => {
                // pawn_double_push is only emitted by pseudo_legal_pawn from rank 1 (white) or rank
                // 6 (black); pinning the (turn, from.rank) pair here keeps the u3 arithmetic below
                // safe AND rules out a bogus effect that pairs, say, black with rank 1 — which
                // would set ep_square on rank 0 and trip the next ply's pawn asserts.
                std.debug.assert(
                    (self.turn == .white and move.from.rank == 1) or
                        (self.turn == .black and move.from.rank == 6),
                );
                const mid_rank: u3 = switch (self.turn) {
                    .white => move.from.rank + 1,
                    .black => move.from.rank - 1,
                };
                self.en_passant_square = .{ .rank = mid_rank, .file = move.from.file };
            },
            // We've already moved the piece at the start, there are no other side effects.
            .move_only => {},
        }

        // 50-move / draw-claim clock: resets on any pawn move or capture, bumps otherwise.
        // `.en_passant` and `.pawn_double_push` both imply a pawn mover (covered by `is_pawn_move`);
        // `.capture` is the only reset path that can fire for a non-pawn.
        if (is_pawn_move or move_effect == .capture) {
            self.halfmove_clock = 0;
        } else {
            self.halfmove_clock += 1;
        }

        // Fullmove number bumps once per full round of play — after black completes a ply. Checked
        // before the turn flip below so "it was black's move just now".
        if (self.turn == .black) {
            self.fullmove_number += 1;
        }

        // TODO: This should likely be something a game effect would enforce, not sure, keeping
        // as is for now for testing purposes.
        self.turn = switch (self.turn) {
            .black => .white,
            .white => .black,
        };

        self.position_hashes.append_assume_capacity(zobrist.hash_state(
            &self.board,
            self.turn,
            self.castling_rights,
            self.en_passant_square,
        ));
        self.command_log.append_assume_capacity(log_entry);
        self.expected_sequence_number += 1;

        // TODO: final_sequence_number should align with the RSM seq lifecycle once it's wired end-to-end.
        // Priority: checkmate > stalemate > 75-move auto-draw.
        if (rules_engine.is_checkmate(&self.board, self.turn, self.castling_rights, self.en_passant_square)) {
            return GameOver{
                .result = .checkmate,
                .winner = self.turn.opponent(),
                .final_sequence_number = log_entry.sequence_number,
            };
        } else if (rules_engine.is_stalemate(&self.board, self.turn, self.castling_rights, self.en_passant_square)) {
            return GameOver{
                .result = .stalemate,
                .winner = null,
                .final_sequence_number = log_entry.sequence_number,
            };
        } else if (self.halfmove_clock >= 150) {
            return GameOver{
                .result = .draw_seventy_five_moves,
                .winner = null,
                .final_sequence_number = log_entry.sequence_number,
            };
        }

        return null;
    }

    fn append_captured_piece(self: *Game, piece: Piece) void {
        std.debug.assert(piece != .empty);
        std.debug.assert(piece.color().? != self.turn);
        std.debug.assert(piece != .white_king and piece != .black_king);
        switch (self.turn) {
            .black => self.captures_by_black.append_assume_capacity(piece),
            .white => self.captures_by_white.append_assume_capacity(piece),
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const test_util = @import("rule_engine/test_util.zig");
const test_helpers = @import("test_helpers.zig");

test "initial state white returns local turn idle" {
    var game: Game = undefined;
    game.init(.white);

    try std.testing.expectEqual(GameState{ .playing = .local_turn }, game.state);
}

test "initial state black returns remote turn waiting" {
    var game: Game = undefined;
    game.init(.black);

    try std.testing.expectEqual(GameState{ .playing = .remote_turn }, game.state);
}

test "init sets board state to initial board state" {
    var game: Game = undefined;
    game.init(.white);

    const b = game.board.squares;

    // White back rank (rank 1 = index 0)
    try std.testing.expectEqual(.white_rook, b[0][0]);
    try std.testing.expectEqual(.white_knight, b[0][1]);
    try std.testing.expectEqual(.white_bishop_dark, b[0][2]);
    try std.testing.expectEqual(.white_queen, b[0][3]);
    try std.testing.expectEqual(.white_king, b[0][4]);
    try std.testing.expectEqual(.white_bishop_light, b[0][5]);
    try std.testing.expectEqual(.white_knight, b[0][6]);
    try std.testing.expectEqual(.white_rook, b[0][7]);

    // White pawns (rank 2 = index 1)
    for (b[1]) |piece| try std.testing.expectEqual(.white_pawn, piece);

    // Empty middle (ranks 3–6 = indices 2–5)
    for (b[2..6]) |rank| for (rank) |piece| try std.testing.expectEqual(.empty, piece);

    // Black pawns (rank 7 = index 6)
    for (b[6]) |piece| try std.testing.expectEqual(.black_pawn, piece);

    // Black back rank (rank 8 = index 7)
    try std.testing.expectEqual(.black_rook, b[7][0]);
    try std.testing.expectEqual(.black_knight, b[7][1]);
    try std.testing.expectEqual(.black_bishop_light, b[7][2]);
    try std.testing.expectEqual(.black_queen, b[7][3]);
    try std.testing.expectEqual(.black_king, b[7][4]);
    try std.testing.expectEqual(.black_bishop_dark, b[7][5]);
    try std.testing.expectEqual(.black_knight, b[7][6]);
    try std.testing.expectEqual(.black_rook, b[7][7]);
}

test "init sets the correct seq number, captures, and position hash" {
    var game: Game = undefined;
    game.init(.white);

    try std.testing.expectEqual(game.expected_sequence_number, 1);
    try std.testing.expectEqual(game.en_passant_square, null);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_white.len);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_black.len);
    try std.testing.expectEqual(@as(usize, 1), game.position_hashes.len);
    try std.testing.expectEqual(zobrist.INITIAL_BOARD_ZOBRIST_HASH, game.position_hashes.slice()[0]);
}

// Smoke tests — primarily exist to force semantic analysis of apply_move and friends. Without a
// test-side caller, Zig skips analyzing pub fns that aren't reached, and field/signature bugs
// can sit in the file undetected.

test "apply_move applies e2-e4 from the starting position" {
    var game: Game = undefined;
    game.init(.white);

    const mv = Move{
        .from = .{ .rank = 1, .file = 4 },
        .to = .{ .rank = 3, .file = 4 },
    };
    try test_helpers.apply_move(&game, mv);

    try std.testing.expectEqual(.empty, game.board.squares[1][4]);
    try std.testing.expectEqual(.white_pawn, game.board.squares[3][4]);
    try std.testing.expectEqual(Color.black, game.turn);
    // Double push registers the passed-over square (e3) as the en-passant target.
    try std.testing.expectEqual(Position{ .rank = 2, .file = 4 }, game.en_passant_square.?);
}

test "apply_move returns IllegalMove when source square is empty" {
    var game: Game = undefined;
    game.init(.white);

    // e4 is empty on the starting board.
    const mv = Move{
        .from = .{ .rank = 3, .file = 4 },
        .to = .{ .rank = 4, .file = 4 },
    };
    try std.testing.expectError(error.IllegalMove, test_helpers.apply_move(&game, mv));
}

test "apply_move: black plays en-passant after white double-push, victim removed and recorded" {
    // Minimal fixture: both kings + the two pawns involved. Goes through the full game
    // state machine — preview_move detects en-passant, commit removes the victim
    // and appends to captures_by_black, the trailing switch clears the ep window.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_pawn, .{ .rank = 1, .file = 4 }); // e2
    test_util.place(&game.board, .black_pawn, .{ .rank = 3, .file = 3 }); // d4

    // 1. e2-e4 — double push, sets ep target to e3 = (2, 4).
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } });
    try std.testing.expectEqual(Position{ .rank = 2, .file = 4 }, game.en_passant_square.?);

    // 1... d4xe3 e.p. — black diagonal capture onto the (empty) ep target square; the
    // victim white pawn physically sits on e4 = (3, 4) and must be cleared.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 3, .file = 3 }, .to = .{ .rank = 2, .file = 4 } });

    try std.testing.expectEqual(Piece.empty, game.board.squares[3][4]); // e4 victim removed
    try std.testing.expectEqual(Piece.empty, game.board.squares[3][3]); // d4 source empty
    try std.testing.expectEqual(Piece.black_pawn, game.board.squares[2][4]); // e3 ep destination
    try std.testing.expectEqual(@as(usize, 1), game.captures_by_black.len);
    try std.testing.expectEqual(Piece.white_pawn, game.captures_by_black.slice()[0]);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_white.len);
    try std.testing.expectEqual(@as(?Position, null), game.en_passant_square);
    try std.testing.expectEqual(Color.white, game.turn);
}

test "apply_move: regular capture appends the victim to captures_by_<turn>" {
    // Confirms the new MoveEffect.capture → Game.append_captured_piece plumbing actually
    // populates the per-side captures list when a capturing move flows through apply_move.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_rook, .{ .rank = 3, .file = 4 }); // e4
    test_util.place(&game.board, .black_pawn, .{ .rank = 5, .file = 4 }); // e6

    // White rook e4 → e6, captures black pawn.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 5, .file = 4 } });

    try std.testing.expectEqual(@as(usize, 1), game.captures_by_white.len);
    try std.testing.expectEqual(Piece.black_pawn, game.captures_by_white.slice()[0]);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_black.len);
    try std.testing.expectEqual(Piece.white_rook, game.board.squares[5][4]);
    try std.testing.expectEqual(Piece.empty, game.board.squares[3][4]);
}

test "apply_move: en_passant_square clears after a non-double-push reply to a double push" {
    // Regression guard for the trailing switch in commit — drop the `else => null`
    // arm and a stale ep target survives indefinitely. Two-move sequence (1. e4, 1... a6)
    // proves the clear leg fires for any non-double-push effect.
    var game: Game = undefined;
    game.init(.white);

    // 1. e4 — sets ep target to e3.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } });
    try std.testing.expectEqual(Position{ .rank = 2, .file = 4 }, game.en_passant_square.?);

    // 1... a6 — black single push, must clear the ep window.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 6, .file = 0 }, .to = .{ .rank = 5, .file = 0 } });
    try std.testing.expectEqual(@as(?Position, null), game.en_passant_square);
}

test "apply_move: white kingside castling moves king + rook and clears both white rights" {
    // End-to-end: preview_move → commit (castling arm moves the rook) → castling_rights_after
    // clears both white flags. Black rights must be untouched.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&game.board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 0 });

    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } });

    try std.testing.expectEqual(Piece.white_king, game.board.squares[0][6]);
    try std.testing.expectEqual(Piece.white_rook, game.board.squares[0][5]);
    try std.testing.expectEqual(Piece.empty, game.board.squares[0][4]);
    try std.testing.expectEqual(Piece.empty, game.board.squares[0][7]);
    try std.testing.expect(!game.castling_rights.white_kingside);
    try std.testing.expect(!game.castling_rights.white_queenside);
    try std.testing.expect(game.castling_rights.black_kingside);
    try std.testing.expect(game.castling_rights.black_queenside);
    try std.testing.expectEqual(Color.black, game.turn);
    try std.testing.expectEqual(@as(?Position, null), game.en_passant_square);
}

test "apply_move: a mating move transitions state to game_over with checkmate result" {
    // Setup: white queen on g3 ready to deliver Qg7#. White knight on f5 defends g7, so the
    // black king cannot capture the queen; white king on a1 keeps own king safe.
    // After the move:
    //   - black king h8 is in check from queen on g7 (NE diagonal one step)
    //   - g8 attacked by queen (north one step) ⇒ no escape
    //   - h7 occupied by friendly pawn ⇒ no escape
    //   - g7 (capturing the queen) attacked by knight on f5 ⇒ illegal escape
    //   - pawn h7→h6 doesn't break the diagonal check ⇒ no block
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .white_queen, .{ .rank = 2, .file = 6 });
    test_util.place(&game.board, .white_knight, .{ .rank = 4, .file = 5 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .black_pawn, .{ .rank = 6, .file = 7 });
    // Castling rights would mention rooks that don't exist here — flip them off so
    // castling_rights_after's invariants stay clean.
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };

    // Qg3-g7#: north slide by 4 ranks.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 2, .file = 6 }, .to = .{ .rank = 6, .file = 6 } });

    switch (game.state) {
        .game_over => |over| {
            try std.testing.expectEqual(GameResult.checkmate, over.result);
            try std.testing.expectEqual(@as(?Color, .white), over.winner);
        },
        else => try std.testing.expect(false),
    }
}

test "apply_move: a stalemating move transitions state to game_over with stalemate result" {
    // Setup: classic K+Q stalemate. White king on f7 controls g7/g8; white queen on g4
    // moves to g6 to take h7's diagonal and reinforce g6's row coverage. After Qg6:
    //   - black king h8 is NOT in check (queen on g6 doesn't reach h8)
    //   - g8 attacked by white king (adjacent) AND queen (file 6 north 2 steps)
    //   - g7 attacked by white king (adjacent) AND queen (file 6 north 1 step)
    //   - h7 attacked by queen (NE diagonal one step)
    //   - black has no other pieces — no legal move exists
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 6, .file = 5 });
    test_util.place(&game.board, .white_queen, .{ .rank = 3, .file = 6 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };

    // Qg4-g6: north slide by 2 ranks.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 3, .file = 6 }, .to = .{ .rank = 5, .file = 6 } });

    switch (game.state) {
        .game_over => |over| {
            try std.testing.expectEqual(GameResult.stalemate, over.result);
            try std.testing.expectEqual(@as(?Color, null), over.winner);
        },
        else => try std.testing.expect(false),
    }
}

test "apply_move: 75-move rule auto-draws when halfmove_clock reaches 150" {
    // Bare K vs K + bishop position; any non-pawn / non-capture move bumps the clock. Pre-set
    // halfmove_clock to 149 so the next quiet move pushes it to 150 and triggers the auto-draw.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .white_knight, .{ .rank = 0, .file = 1 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };
    game.halfmove_clock = 149;

    // Nb1-a3 — quiet knight move; non-pawn, non-capture, no check, no mate, no stalemate.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 0, .file = 1 }, .to = .{ .rank = 2, .file = 0 } });

    try std.testing.expectEqual(@as(u16, 150), game.halfmove_clock);
    switch (game.state) {
        .game_over => |over| {
            try std.testing.expectEqual(GameResult.draw_seventy_five_moves, over.result);
            try std.testing.expectEqual(@as(?Color, null), over.winner);
        },
        else => try std.testing.expect(false),
    }
}

test "apply_move: 75-move rule does NOT trigger when clock lands at 149" {
    // Same setup but pre-set to 148 — the move bumps the clock to 149, which is one short.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .white_knight, .{ .rank = 0, .file = 1 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };
    game.halfmove_clock = 148;

    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 0, .file = 1 }, .to = .{ .rank = 2, .file = 0 } });

    try std.testing.expectEqual(@as(u16, 149), game.halfmove_clock);
    switch (game.state) {
        .playing => {},
        else => try std.testing.expect(false),
    }
}

test "apply_move: 75-move clock resets on a pawn move even when at 149" {
    // Tracking guard: the reset path still fires when the clock is one short of the threshold
    // — i.e. a pawn push at clock=149 doesn't accidentally tip into draw_seventy_five_moves.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .white_pawn, .{ .rank = 1, .file = 4 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };
    game.halfmove_clock = 149;

    // e2-e3 — pawn single push.
    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 2, .file = 4 } });

    try std.testing.expectEqual(@as(u16, 0), game.halfmove_clock);
    switch (game.state) {
        .playing => {},
        else => try std.testing.expect(false),
    }
}

test "apply_move: checkmate beats 75-move rule when both fire on the same ply" {
    // Same Qg7# fixture as the checkmate test, but pre-set halfmove_clock to 149. The mating
    // queen move is non-pawn / non-capture so the clock would otherwise reach 150. Result must
    // be .checkmate, not .draw_seventy_five_moves.
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
    game.halfmove_clock = 149;

    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 2, .file = 6 }, .to = .{ .rank = 6, .file = 6 } });

    switch (game.state) {
        .game_over => |over| {
            try std.testing.expectEqual(GameResult.checkmate, over.result);
            try std.testing.expectEqual(@as(?Color, .white), over.winner);
        },
        else => try std.testing.expect(false),
    }
}

test "apply_move: stalemate beats 75-move rule when both fire on the same ply" {
    // Same K+Q stalemate fixture, but pre-set halfmove_clock to 149. The stalemating queen
    // move is non-pawn / non-capture so the clock would otherwise reach 150. Result must be
    // .stalemate, not .draw_seventy_five_moves.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 6, .file = 5 });
    test_util.place(&game.board, .white_queen, .{ .rank = 3, .file = 6 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    game.castling_rights = .{
        .white_kingside = false,
        .white_queenside = false,
        .black_kingside = false,
        .black_queenside = false,
    };
    game.halfmove_clock = 149;

    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 3, .file = 6 }, .to = .{ .rank = 5, .file = 6 } });

    switch (game.state) {
        .game_over => |over| {
            try std.testing.expectEqual(GameResult.stalemate, over.result);
            try std.testing.expectEqual(@as(?Color, null), over.winner);
        },
        else => try std.testing.expect(false),
    }
}

test "apply_move: a non-mating move keeps the game in playing state" {
    // Regression guard: after the mate-detection logic was added to commit, a quiet move
    // from the starting position must NOT flip state to game_over.
    var game: Game = undefined;
    game.init(.white);

    try test_helpers.apply_move(&game, .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } });

    switch (game.state) {
        .playing => {},
        else => try std.testing.expect(false),
    }
}

test "apply_move: replays the Immortal Game and detects Be7# as checkmate at move 45" {
    // Anderssen vs Kieseritzky, London 1851. 44 plies in `.playing` state plus a 45th mating
    // ply played separately. Mirrors the bench's IMMORTAL_GAME sequence. End-to-end coverage
    // of the engine: 45 ply through preview_move + commit across captures, sacrifices,
    // knight forks, with a real checkmate at the end that exercises the new `is_checkmate`
    // plumbing.
    const game_moves = [_]Move{
        // 1. e4 e5
        .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } },
        .{ .from = .{ .rank = 6, .file = 4 }, .to = .{ .rank = 4, .file = 4 } },
        // 2. f4 exf4
        .{ .from = .{ .rank = 1, .file = 5 }, .to = .{ .rank = 3, .file = 5 } },
        .{ .from = .{ .rank = 4, .file = 4 }, .to = .{ .rank = 3, .file = 5 } },
        // 3. Bc4 Qh4+
        .{ .from = .{ .rank = 0, .file = 5 }, .to = .{ .rank = 3, .file = 2 } },
        .{ .from = .{ .rank = 7, .file = 3 }, .to = .{ .rank = 3, .file = 7 } },
        // 4. Kf1 b5
        .{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 5 } },
        .{ .from = .{ .rank = 6, .file = 1 }, .to = .{ .rank = 4, .file = 1 } },
        // 5. Bxb5 Nf6
        .{ .from = .{ .rank = 3, .file = 2 }, .to = .{ .rank = 4, .file = 1 } },
        .{ .from = .{ .rank = 7, .file = 6 }, .to = .{ .rank = 5, .file = 5 } },
        // 6. Nf3 Qh6
        .{ .from = .{ .rank = 0, .file = 6 }, .to = .{ .rank = 2, .file = 5 } },
        .{ .from = .{ .rank = 3, .file = 7 }, .to = .{ .rank = 5, .file = 7 } },
        // 7. d3 Nh5
        .{ .from = .{ .rank = 1, .file = 3 }, .to = .{ .rank = 2, .file = 3 } },
        .{ .from = .{ .rank = 5, .file = 5 }, .to = .{ .rank = 4, .file = 7 } },
        // 8. Nh4 Qg5
        .{ .from = .{ .rank = 2, .file = 5 }, .to = .{ .rank = 3, .file = 7 } },
        .{ .from = .{ .rank = 5, .file = 7 }, .to = .{ .rank = 4, .file = 6 } },
        // 9. Nf5 c6
        .{ .from = .{ .rank = 3, .file = 7 }, .to = .{ .rank = 4, .file = 5 } },
        .{ .from = .{ .rank = 6, .file = 2 }, .to = .{ .rank = 5, .file = 2 } },
        // 10. g4 Nf6
        .{ .from = .{ .rank = 1, .file = 6 }, .to = .{ .rank = 3, .file = 6 } },
        .{ .from = .{ .rank = 4, .file = 7 }, .to = .{ .rank = 5, .file = 5 } },
        // 11. Rg1 cxb5
        .{ .from = .{ .rank = 0, .file = 7 }, .to = .{ .rank = 0, .file = 6 } },
        .{ .from = .{ .rank = 5, .file = 2 }, .to = .{ .rank = 4, .file = 1 } },
        // 12. h4 Qg6
        .{ .from = .{ .rank = 1, .file = 7 }, .to = .{ .rank = 3, .file = 7 } },
        .{ .from = .{ .rank = 4, .file = 6 }, .to = .{ .rank = 5, .file = 6 } },
        // 13. h5 Qg5
        .{ .from = .{ .rank = 3, .file = 7 }, .to = .{ .rank = 4, .file = 7 } },
        .{ .from = .{ .rank = 5, .file = 6 }, .to = .{ .rank = 4, .file = 6 } },
        // 14. Qf3 Ng8
        .{ .from = .{ .rank = 0, .file = 3 }, .to = .{ .rank = 2, .file = 5 } },
        .{ .from = .{ .rank = 5, .file = 5 }, .to = .{ .rank = 7, .file = 6 } },
        // 15. Bxf4 Qf6
        .{ .from = .{ .rank = 0, .file = 2 }, .to = .{ .rank = 3, .file = 5 } },
        .{ .from = .{ .rank = 4, .file = 6 }, .to = .{ .rank = 5, .file = 5 } },
        // 16. Nc3 Bc5
        .{ .from = .{ .rank = 0, .file = 1 }, .to = .{ .rank = 2, .file = 2 } },
        .{ .from = .{ .rank = 7, .file = 5 }, .to = .{ .rank = 4, .file = 2 } },
        // 17. Nd5 Qxb2
        .{ .from = .{ .rank = 2, .file = 2 }, .to = .{ .rank = 4, .file = 3 } },
        .{ .from = .{ .rank = 5, .file = 5 }, .to = .{ .rank = 1, .file = 1 } },
        // 18. Bd6 Bxg1
        .{ .from = .{ .rank = 3, .file = 5 }, .to = .{ .rank = 5, .file = 3 } },
        .{ .from = .{ .rank = 4, .file = 2 }, .to = .{ .rank = 0, .file = 6 } },
        // 19. e5 Qxa1+
        .{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 4, .file = 4 } },
        .{ .from = .{ .rank = 1, .file = 1 }, .to = .{ .rank = 0, .file = 0 } },
        // 20. Ke2 Na6
        .{ .from = .{ .rank = 0, .file = 5 }, .to = .{ .rank = 1, .file = 4 } },
        .{ .from = .{ .rank = 7, .file = 1 }, .to = .{ .rank = 5, .file = 0 } },
        // 21. Nxg7+ Kd8
        .{ .from = .{ .rank = 4, .file = 5 }, .to = .{ .rank = 6, .file = 6 } },
        .{ .from = .{ .rank = 7, .file = 4 }, .to = .{ .rank = 7, .file = 3 } },
        // 22. Qf6+ Nxf6
        .{ .from = .{ .rank = 2, .file = 5 }, .to = .{ .rank = 5, .file = 5 } },
        .{ .from = .{ .rank = 7, .file = 6 }, .to = .{ .rank = 5, .file = 5 } },
        // 23. Be7# (checkmate)
        .{ .from = .{ .rank = 5, .file = 3 }, .to = .{ .rank = 6, .file = 4 } },
    };

    var game: Game = undefined;
    game.init(.white);

    for (game_moves[0 .. game_moves.len - 1], 0..) |mv, i| {
        // Turn BEFORE the move flips is what apply_move will mutate.
        const turn_before: Color = if (i % 2 == 0) .white else .black;
        try std.testing.expectEqual(turn_before, game.turn);
        try test_helpers.apply_move(&game, mv);
        switch (game.state) {
            .playing => {},
            else => try std.testing.expect(false),
        }
        // The engine flips the turn at the end of each commit — confirm it landed on
        // the opponent.
        try std.testing.expectEqual(turn_before.opponent(), game.turn);
    }

    // Final move: Be7# — engine must classify as mate.
    try test_helpers.apply_move(&game, game_moves[game_moves.len - 1]);
    switch (game.state) {
        .game_over => |over| {
            try std.testing.expectEqual(GameResult.checkmate, over.result);
            try std.testing.expectEqual(@as(?Color, .white), over.winner);
        },
        else => try std.testing.expect(false),
    }
}

test "apply_move_with_promotion: white pawn e7-e8 promotes to queen" {
    // End-to-end of the promotion fork: local_command → prompt_for_promotion →
    // local_promotion_choice → send_proposal → auto-ack → commit's promotion arm
    // swaps the pawn for the chosen piece. Black king on h8 has g7/h7 escapes from the
    // queen on e8, so commit returns no game-over and state lands in remote_turn.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_pawn, .{ .rank = 6, .file = 4 }); // e7

    const mv = Move{ .from = .{ .rank = 6, .file = 4 }, .to = .{ .rank = 7, .file = 4 } };
    try test_helpers.apply_move_with_promotion(&game, mv, .queen);

    try std.testing.expectEqual(Piece.empty, game.board.squares[6][4]);
    try std.testing.expectEqual(Piece.white_queen, game.board.squares[7][4]);
    try std.testing.expectEqual(Color.black, game.turn);
}

test "tick: local_command with legal play transitions to proposing and emits send_proposal" {
    // Smoke test for tick — same rationale as the apply_move smoke tests above. Drives the
    // local_turn → local_command → .play arm so Zig analyzes the body; without a caller,
    // signature/field bugs in the arm sit undetected (e.g. a wrong GameEffect variant or a
    // value passed where a pointer is expected won't surface until something reaches it).
    var game: Game = undefined;
    game.init(.white);

    var out: BoundedArray(GameEffect, Game.MAX_EFFECTS) = .{};
    const event = GameEvent{ .local_command = .{
        .command = .{ .play = .{
            .move = .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } },
            .promotion = null,
        } },
        .think_time_ms = 0,
        .now_ms = 0,
    } };
    game.tick(event, &out);

    switch (game.state) {
        .playing => |playing| switch (playing) {
            .proposing => |prop| {
                try std.testing.expectEqual(@as(u32, 1), prop.pending.sequence_number);
                try std.testing.expectEqual(Color.white, prop.pending.issued_by);
            },
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }

    try std.testing.expectEqual(@as(usize, 1), out.len);
    switch (out.slice()[0]) {
        .send_proposal => |entry| try std.testing.expectEqual(@as(u32, 1), entry.sequence_number),
        else => try std.testing.expect(false),
    }
}

// Pulls the whole rule engine into the test runner. A normal `@import` (see the top of this
// file) forces *analysis* but not test discovery; the `_ = @import` form inside a test block
// is what adds a file's `test` blocks to the running binary.
test {
    _ = @import("rule_engine/rules.zig");
    _ = @import("rule_engine/check_helper.zig");
    _ = @import("rule_engine/shared.zig");
    _ = @import("rule_engine/test_util.zig");
    _ = @import("rule_engine/zobrist.zig");
    _ = @import("game_protocol_tests.zig");
}
