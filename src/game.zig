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

pub const GameOver = struct {
    result: GameResult,
    winner: ?Color,
    /// Pins the exact RSM command that ended the game — used for rematch setup
    /// (start from final_sequence_number + 1), for persistence, and for disambiguating commands
    /// that share a move_number (e.g. a move and a resignation both issued during move 30 are
    /// distinct commands, distinct seqs).
    final_sequence_number: u32,
};

/// In-flight transaction the player is participating in. Held while waiting for the cluster's
/// COMMIT or ABORT after the player voted yes on PREPARE. From `prepared` onward the player can
/// never voluntarily abort — the durable `prepared(seq)` record commits us to honoring the cluster's
/// eventual decision.
pub const InFlight = struct {
    sequence_number: u32,
    entry: LogEntry,
    /// Predicted zobrist after applying `entry.command`. Sent in VOTE; the cluster cross-checks
    /// against followers and the opponent's predicted hash before deciding COMMIT vs ABORT.
    my_post_apply_zobrist: u64,
    prepared_at_ms: u32,
};

pub const PlayerState = union(enum) {
    /// Not currently in a transaction. Local input flows from here on our turn; PREPAREs for
    /// either side's move land here too.
    idle,

    /// User picked a move that requires a promotion piece. Holding the half-formed move until
    /// the user supplies the piece, then we SUBMIT.
    awaiting_promotion_piece: struct {
        pending_move: Move,
        issued_at_ms: u32,
    },

    /// SUBMIT sent; waiting for PREPARE from the leader.
    awaiting_prepare: struct {
        submitted_command: GameCommand,
        submitted_at_ms: u32,
    },

    /// Voted yes; fsynced `prepared(seq)`. Waiting for COMMIT or ABORT.
    prepared: InFlight,

    /// Cluster (or the leader specifically) unreachable. Reconnect goes via HELLO + RESUME_GAME,
    /// so we don't snapshot any prior protocol substate here — the durable log is the source of
    /// truth on reconnect.
    paused_disconnected: struct { deadline_ms: u32 },

    /// Game is over with the result stored in the inner struct.
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

/// The canonical RSM command record. Carried inside PREPARE; on the coord side every committed
/// LogEntry maps to one Raft log entry.
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
    /// Duration the player spent on this move. UI hint — the coord's `commit_ts_ms` is the
    /// authoritative timestamp for the commit.
    time_taken_ms: u32,
};

pub const LocalRejectionReason = enum {
    illegal_move,
    out_of_turn,

    /// A new SUBMIT-bound action was attempted while we already have an in-flight transaction
    /// (awaiting_prepare or prepared).
    already_in_flight,

    game_ended,

    /// Cluster (or the leader specifically) is currently unreachable. Distinct from `game_ended`:
    /// the game is still live, the player just can't progress until reconnect or until the
    /// disconnect-grace timer expires and converts this into a real game-over.
    disconnected,

    awaiting_promotion_piece,

    /// Represents a rejection when a promotion piece choice arrives outside of
    /// awaiting_promotion_piece.
    unsolicited_promotion_choice,
};

/// VOTE-no rejection reason.
pub const NackReason = enum {
    illegal_move,

    /// PREPARE's `prior_state_hash` doesn't match our local zobrist — our state diverged from
    /// the leader's.
    prior_state_drift,

    /// PREPARE's seq isn't `expected_sequence_number`.
    seq_gap,

    /// PREPARE's `entry.issued_by` doesn't match the player whose turn it is.
    wrong_issuer,
};

/// Reason the leader carries in an ABORT message.
pub const AbortReason = enum {
    player_voted_no,
    vote_timeout,
    zobrist_mismatch,
    coordinator_rejected,
    stepped_down,
    manual,
};

pub const Vote = enum { yes, no };

/// Authoritative chess clock state delivered by the coord on every COMMIT. The player holds it
/// for rendering only; the cluster owns the canonical clock.
pub const ClockState = struct {
    white_remaining_ms: u32,
    black_remaining_ms: u32,
    /// The color whose clock is currently counting down. Null when paused (between commits or
    /// during disconnect grace).
    running: ?Color,
};

pub const StatusDecision = enum { commit, abort, unknown };

pub const PrepareReceived = struct {
    sequence_number: u32,
    entry: LogEntry,
    /// Leader's pre-apply zobrist for this game. Players vote no if it diverges.
    prior_state_hash: u64,
};

pub const CommitReceived = struct {
    sequence_number: u32,
    post_clock_state: ClockState,
};

pub const AbortReceived = struct {
    sequence_number: u32,
    reason: AbortReason,
};

pub const StatusReply = struct {
    sequence_number: u32,
    decision: StatusDecision,
};

pub const GameEvent = union(enum) {
    local_command: struct {
        command: GameCommand,

        /// Amount of time player took to make this move.
        think_time_ms: u32,

        /// The Loop's clock at dispatch.
        now_ms: u32,
    },

    /// The local player has chosen a promotion piece for a pawn.
    local_promotion_choice: struct {
        piece: PromotionPiece,
        think_time_ms: u32,
        now_ms: u32,
    },

    prepare_received: PrepareReceived,
    commit_received: CommitReceived,
    abort_received: AbortReceived,
    status_reply_received: StatusReply,
    resume_ack_received,

    /// Render-only tick. Authoritative clock advancement happens on the coord; the local clock
    /// here is for UI countdown only.
    clock_tick,

    /// Local guard: PREPARE→COMMIT stalled past `VOTE_TIMEOUT_MS`. Drives a STATUS query.
    vote_timeout,

    coordinator_disconnected,
    coordinator_reconnected,
    disconnect_timer_expired,
};

/// Player-side durable log record. Fsynced before the corresponding wire message goes out.
pub const FsyncRecord = union(enum) {
    prepared: struct {
        sequence_number: u32,
        entry: LogEntry,
        prior_state_hash: u64,
    },
    committed: struct { sequence_number: u32 },
    aborted: struct { sequence_number: u32 },
};

pub const GameEffect = union(enum) {
    /// Initiate the cluster handshake (after connect or reconnect).
    send_hello,

    /// SUBMIT a freshly-issued command to the leader. No seq yet — the leader assigns.
    send_submit: struct {
        command: GameCommand,
        think_time_ms: u32,
    },

    /// VOTE on a PREPARE. Carries our predicted post-apply zobrist for the cluster's 5/7-way
    /// cross-check.
    send_vote: struct {
        sequence_number: u32,
        vote: Vote,
        post_apply_zobrist: u64,
        reason: ?NackReason,
    },

    /// APPLIED ack after the local apply. Carries the actual post-apply zobrist; the cluster
    /// re-runs the hash check post-commit (stricter than the vote-time check, since divergence
    /// here means non-deterministic apply rather than mere disagreement).
    send_applied: struct {
        sequence_number: u32,
        post_apply_zobrist: u64,
    },

    /// Ask the leader to resolve an in-doubt prepared(seq) found during log replay.
    send_status_request: struct { sequence_number: u32 },

    /// Reconnect resume request. Player declares last_known_seq + last_known_zobrist; cluster
    /// catches us up.
    send_resume_game: struct {
        last_known_sequence_number: u32,
        last_known_zobrist: u64,
    },

    /// Append a record to the player's durable log. Must complete before the next outbound
    /// message that depends on it.
    fsync_log_record: FsyncRecord,

    local_rejected: struct { reason: LocalRejectionReason },
    render,
    game_ended: GameResult,
    prompt_for_promotion: struct { color: Color },
};

/// Represents the game being played from the local player's point of view. Holds the chess RSM
/// state plus the player-side protocol state machine for the coordinated 2PC dance with the
/// coordinator cluster.
pub const Game = struct {
    /// The cluster-assigned game id. Tagged on every wire message.
    game_id: u64,

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

    state: PlayerState,

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

    /// Render-only mirror. Authoritative clock state lives on the cluster; refreshed from
    /// COMMIT.post_clock_state on each apply.
    chess_clock: ClockState,

    /// Upper bound on effects emitted by a single tick(). 16 leaves headroom for paths that
    /// stack multiple effects (e.g. fsync_log_record + send_vote + render + game_ended).
    pub const MAX_EFFECTS = 16;

    /// Upper bound on position-hash entries. 512 is ample for a real chess
    /// game (longest practical games run ~300 half-moves; the fifty-move rule caps growth).
    const MAX_LOG = 512;

    pub fn init(self: *Game, game_id: u64, local_color: Color) void {
        self.* = .{
            .game_id = game_id,
            .board = undefined,
            .state = .idle,
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
            .chess_clock = .{
                .white_remaining_ms = 0,
                .black_remaining_ms = 0,
                .running = null,
            },
        };
        self.board.init();
        self.position_hashes.append_assume_capacity(zobrist.INITIAL_BOARD_ZOBRIST_HASH);
    }

    /// The state machine with side effects. It reads the game event, mutates the state of the board
    /// and tracked state and returns the side-effects.
    pub fn tick(self: *Game, event: GameEvent, out: *BoundedArray(GameEffect, MAX_EFFECTS)) void {
        std.debug.assert(self.expected_sequence_number >= 1);
        std.debug.assert(self.position_hashes.len <= MAX_LOG);

        switch (self.state) {
            .idle => switch (event) {
                .local_command => |payload| switch (payload.command) {
                    .play => |play| self.handle_local_play(play, payload.think_time_ms, payload.now_ms, out),
                    // TODO: resign / offer_draw / accept_draw / decline_draw / claim_draw arms.
                    else => @panic("non-play GameCommand variants not yet implemented in tick"),
                },
                .local_promotion_choice => out.append_assume_capacity(.{
                    .local_rejected = .{ .reason = .unsolicited_promotion_choice },
                }),
                // TODO: coord-driven 2PC (PREPARE → VOTE → COMMIT/ABORT/APPLIED).
                .prepare_received, .commit_received, .abort_received => @panic("TODO: coord 2PC arms"),
                // TODO: recovery path (STATUS, RESUME_GAME).
                .status_reply_received, .resume_ack_received => @panic("TODO: recovery arms"),
                // Vote-timeout-without-in-flight would be a coord bug; treat as no-op until the
                // 2PC arms are wired up.
                .vote_timeout => {},
                // TODO: UI clock countdown / disconnect bookkeeping.
                .clock_tick, .coordinator_disconnected, .coordinator_reconnected, .disconnect_timer_expired => {},
            },
            .awaiting_promotion_piece => |held| switch (event) {
                .local_promotion_choice => |choice| self.handle_promotion_choice(held, choice, out),
                .local_command => out.append_assume_capacity(.{
                    .local_rejected = .{ .reason = .awaiting_promotion_piece },
                }),
                // TODO: coord traffic during local promotion-piece prompt; should be rare since
                // the coord won't issue PREPARE for our turn until we SUBMIT.
                .prepare_received, .commit_received, .abort_received, .status_reply_received, .resume_ack_received => @panic("TODO: coord traffic in awaiting_promotion_piece"),
                .vote_timeout, .clock_tick, .coordinator_disconnected, .coordinator_reconnected, .disconnect_timer_expired => {},
            },
            // TODO: in-flight transaction events. awaiting_prepare receives PREPARE (validate
            // matches our submitted command, fsync, vote yes, transition to prepared); prepared
            // receives COMMIT (fsync, apply via commit(), send_applied, transition to idle or
            // game_over) or ABORT (fsync aborted, transition to idle).
            .awaiting_prepare, .prepared => @panic("TODO: in-flight transaction arms"),
            .paused_disconnected => switch (event) {
                .local_command, .local_promotion_choice => out.append_assume_capacity(.{
                    .local_rejected = .{ .reason = .disconnected },
                }),
                // TODO: reconnect handling (HELLO → RESUME_GAME → resume_ack_received → restore
                // in_flight from durable log; disconnect_timer_expired → game_over{disconnect}).
                .prepare_received, .commit_received, .abort_received, .status_reply_received, .resume_ack_received, .coordinator_reconnected, .disconnect_timer_expired => @panic("TODO: reconnect arms"),
                .vote_timeout, .clock_tick, .coordinator_disconnected => {},
            },
            .game_over => switch (event) {
                .local_command, .local_promotion_choice => out.append_assume_capacity(.{
                    .local_rejected = .{ .reason = .game_ended },
                }),
                // No-op: game's over, nothing to do.
                else => {},
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
        if (self.turn != self.local_color) {
            out.append_assume_capacity(.{ .local_rejected = .{ .reason = .out_of_turn } });
            return;
        }

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
                .awaiting_promotion_piece = .{
                    .pending_move = play.move,
                    .issued_at_ms = now_ms,
                },
            };
            out.append_assume_capacity(.{ .prompt_for_promotion = .{ .color = self.local_color } });
            return;
        }

        self.submit(.{ .play = play }, think_time_ms, now_ms, out);
    }

    fn handle_promotion_choice(
        self: *Game,
        held: @FieldType(PlayerState, "awaiting_promotion_piece"),
        choice: @FieldType(GameEvent, "local_promotion_choice"),
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        self.submit(
            .{ .play = .{ .move = held.pending_move, .promotion = choice.piece } },
            choice.think_time_ms,
            held.issued_at_ms,
            out,
        );
    }

    /// Transitions to `awaiting_prepare` and emits send_submit. No fsync here — the first fsync
    /// happens at PREPARE time, when the player records `prepared(seq)` before voting yes.
    fn submit(
        self: *Game,
        command: GameCommand,
        think_time_ms: u32,
        submitted_at_ms: u32,
        out: *BoundedArray(GameEffect, MAX_EFFECTS),
    ) void {
        self.state = .{
            .awaiting_prepare = .{
                .submitted_command = command,
                .submitted_at_ms = submitted_at_ms,
            },
        };
        out.append_assume_capacity(.{
            .send_submit = .{
                .command = command,
                .think_time_ms = think_time_ms,
            },
        });
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

// Pulls the rule engine into the test runner. A normal `@import` (see the top of this
// file) forces *analysis* but not test discovery; the `_ = @import` form inside a test block
// is what adds a file's `test` blocks to the running binary.
test {
    _ = @import("rule_engine/rules.zig");
    _ = @import("rule_engine/check_helper.zig");
    _ = @import("rule_engine/shared.zig");
    _ = @import("rule_engine/test_util.zig");
    _ = @import("rule_engine/zobrist.zig");
}
