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

/// It's this players turn.
pub const LocalTurn = enum {
    /// The player has yet to make a move.
    idle,

    /// The player has made his move and is waiting for acknowledgement from the opponent.
    proposing,
};

/// It's the opponents turn to move, we're just waiting on them.
pub const RemoteTurn = enum {
    waiting,
};

/// Playing represents either local or opponents turn, depending on whose turn it is.
pub const Playing = union(enum) {
    local_turn: LocalTurn,
    remote_turn: RemoteTurn,

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

/// The state of the game. Can be playing, ended, or disconnected.
const GameState = union(enum) {
    /// The game is still ongoing.
    playing: Playing,

    /// One of the players is disconnected.
    paused_disconnected: PausedDisconnected,

    /// Game is over with the result stored in the enum. `final_seq` pins the exact RSM
    /// command that ended the game — used for rematch setup (start from final_seq + 1), for
    /// persistence, and for disambiguating commands that share a move_number (e.g. a move
    /// and a resignation both issued during move 30 are distinct commands, distinct seqs).
    game_over: struct { result: GameResult, winner: ?Color, final_seq: u32 },
};

pub const DrawClaim = enum {
    fifty_moves,
    threefold_repetition,
};

pub const GameCommand = union(enum) {
    move: struct { move: Move, promotion: ?PromotionPiece },
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

    /// The full move number
    move_number: u16,

    /// That game command that corresponds to this entry.
    command: GameCommand,

    /// Which player initiated this log entry.
    issued_by: Color,

    // We don't send the original clock times because it would be unnecessary in my opinion, what we
    // measure is how much time was spent on a move and the clock is decremented based off of that
    // metric, when you think like that sending the delta makes more sense.
    //
    /// Duration the player spent on this move.
    time_taken_ms: u32,
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
    seq: u32,
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
    local_command: GameCommand,
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
    render,
    game_ended: GameResult,

    /// Starts the auto timer when the opponent disconnects. The current player is directly awarded
    /// the win if the opponent fails to reconnect within a certain time period.
    start_disconnect_timer: u32,
};

/// Represents the game being played. Holds the complete data of the game including players move
/// history, game state, the log for the RSM.
pub const Game = struct {
    /// Stores the current state of the Board.
    board: Board,

    /// Stores whose turn it is, either black or white.
    turn: Color,

    /// What player does this game instance belong to, either black or white.
    player_color: Color,

    // Description copied with care from the internet :p
    /// A full move consists of two consecutive turns—one by White and one by Black—whereas a
    /// half-move (or "ply") refers to a single turn by one player.
    fullmove_number: u16,

    /// Counts the number of half moves since the last capture or pawn move.
    /// Required when one of the players want's to propose/claim a draw under the 50 move rule.
    halfmove_clock: u16,

    /// Game state, showing if playing, disconnected or ended.
    state: GameState,

    /// Pieces white has captured from black. Bounded to 15 since white can capture at most 15 of
    /// black's 16 pieces — the king is never captured.
    captures_by_white: BoundedArray(Piece, 15),

    /// Pieces black has captured from white. Same bound and reasoning as captures_by_white.
    captures_by_black: BoundedArray(Piece, 15),

    /// Position has that tracks if the position has been repeated, required for three-fold
    /// repetition draw rule.
    position_hash: BoundedArray(u64, MAX_LOG),

    /// The next expected sequence number.
    expected_seq: u32,

    /// Castling Rights, whether a player has them or not.
    castling_rights: CastlingRights,

    /// The square an opposing pawn could capture to, if the last move was a two-square pawn
    /// advance. Cleared on every move that doesn't create a new en-passant target.
    en_passant_square: ?Position,

    /// Upper bound on effects emitted by a single tick(). 16 leaves headroom for paths that
    /// stack multiple effects (e.g. send_ack + apply + render + game_ended + start_*_timer).
    const MAX_EFFECTS = 16;

    /// Upper bound on command-log and position-hash entries. 512 is ample for a real chess
    /// game (longest practical games run ~300 half-moves; the fifty-move rule caps growth).
    const MAX_LOG = 512;

    /// Returns the initial game state based on the color of the pieces.
    pub fn initial_state(color: Color) GameState {
        return switch (color) {
            .white => GameState{ .playing = .{ .local_turn = .idle } },
            .black => GameState{ .playing = .{ .remote_turn = .waiting } },
        };
    }

    /// Initializes the Game struct in place.
    pub fn init(self: *Game, player_color: Color) void {
        self.* = .{
            .board = undefined,
            .state = initial_state(player_color),
            .turn = .white,
            .halfmove_clock = 0,
            .fullmove_number = 1,
            .player_color = player_color,
            .captures_by_white = .{},
            .captures_by_black = .{},
            .position_hash = .{},
            .expected_seq = 1,
            .castling_rights = .{},
            .en_passant_square = null,
        };
        self.board.init();
    }

    /// The state machine with side effects. It reads the game event, mutates the state of the board
    /// and tracked state and returns the side-effects.
    ///
    /// For now invalid events will end in panic, will be handled down the line.
    pub fn tick(self: *Game, event: GameEvent) BoundedArray(GameEffect, MAX_EFFECTS) {
        // TODO: Wire up logic for each event
        std.debug.assert(self.expected_seq >= 1);
        std.debug.assert(self.position_hash.len <= MAX_LOG);

        _ = event;
        const effects: BoundedArray(GameEffect, MAX_EFFECTS) = .{};

        switch (self.state) {
            .playing => |playing| switch (playing) {
                .local_turn => |lt| switch (lt) {
                    .idle => {},
                    .proposing => {},
                },
                .remote_turn => |rt| switch (rt) {
                    .waiting => {},
                },
                .awaiting_draw_response => {},
            },
            .paused_disconnected => {},
            .game_over => {},
        }

        return effects;
    }

    /// Tries to play the inputted move. If it's a legal move updates the board position and handles
    /// the captures. Returns error.InvalidMove in case the move is illegal.
    pub fn play_move(self: *Game, move: Move) !void {
        // When preview_move grows a new error variant the exhaustive switch below will fail
        // to compile — that's the signal to add a TODO (or a proper handler) for it.
        const move_effect = rules_engine.preview_move(
            &self.board,
            self.turn,
            move,
            self.en_passant_square,
            self.castling_rights,
        ) catch |err| switch (err) {
            // TODO: Surface InvalidMove as a game effect (NACK) instead of propagating raw.
            error.InvalidMove => return err,
        };

        // Rejected here, not inside apply_effect: both play_move (castling_rights assignment
        // below) and apply_effect (pre-switch board.move + en_passant_square reset) mutate state
        // before a `.promotion` arm would run. Erroring from either spot would leave the game
        // half-applied; gating up front keeps the reject path mutation-free.
        if (move_effect == .promotion) {
            return error.PromotionNotSupported;
        }

        // Snapshot the mover's piece identity BEFORE `apply_effect` mutates the board — the 50-move
        // clock below needs to know whether this was a pawn move, and the source square is about to
        // change.
        const moving_piece = self.board.board_state[move.from.rank][move.from.file];
        const is_pawn_move = moving_piece == .white_pawn or moving_piece == .black_pawn;

        self.castling_rights = rules_engine.castling_rights_after(
            &self.board,
            self.turn,
            move,
            move_effect,
            self.castling_rights,
        );
        self.apply_effect(move, move_effect);

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
    }

    /// Applies the move effect to the game.
    fn apply_effect(self: *Game, move: Move, effect: MoveEffect) void {
        self.board.move(move.from, move.to);

        // En-passant target is a one-ply window: only valid immediately after a double push.
        // Reset here; the pawn_double_push arm below re-sets it to the square the pawn passed over.
        self.en_passant_square = null;

        switch (effect) {
            .capture => |captured_piece| self.append_captured_piece(captured_piece),
            // play_move rejects `.promotion` with error.PromotionNotSupported before this
            // switch runs — reaching here means the guard was removed without wiring up
            // the promotion apply logic (pawn clear + promoted-piece set + captured-piece
            // append conditional on ep.capture). Keep these linked so the TODO can't rot.
            .promotion => unreachable,
            .en_passant => |ep| {
                const captured_pawn: Piece = switch (self.turn) {
                    .white => .black_pawn,
                    .black => .white_pawn,
                };
                self.append_captured_piece(captured_pawn);
                self.board.clear(ep.captured_pawn_at);
            },
            .castling => |c| {
                self.board.move(c.rook_from, c.rook_to);
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

test "intial state white returns local turn idle" {
    var game: Game = undefined;
    game.init(.white);

    try std.testing.expectEqual(GameState{ .playing = .{ .local_turn = .idle } }, game.state);
}

test "intial state black returns remote turn waiting" {
    var game: Game = undefined;
    game.init(.black);

    try std.testing.expectEqual(GameState{ .playing = .{ .remote_turn = .waiting } }, game.state);
}

test "init sets board state to initial board state" {
    var game: Game = undefined;
    game.init(.white);

    const b = game.board.board_state;

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
    for (b[1]) |p| try std.testing.expectEqual(.white_pawn, p);

    // Empty middle (ranks 3–6 = indices 2–5)
    for (b[2..6]) |rank| for (rank) |p| try std.testing.expectEqual(.empty, p);

    // Black pawns (rank 7 = index 6)
    for (b[6]) |p| try std.testing.expectEqual(.black_pawn, p);

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

test "inti sets the correct seq number, captures, and position hash" {
    var game: Game = undefined;
    game.init(.white);

    try std.testing.expectEqual(game.expected_seq, 1);
    try std.testing.expectEqual(game.en_passant_square, null);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_white.len);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_black.len);
    try std.testing.expectEqual(@as(usize, 0), game.position_hash.len);
}

// Smoke tests — primarily exist to force semantic analysis of play_move and friends. Without a
// test-side caller, Zig skips analyzing pub fns that aren't reached, and field/signature bugs
// can sit in the file undetected.

test "play_move applies e2-e4 from the starting position" {
    var game: Game = undefined;
    game.init(.white);

    const mv = Move{
        .from = .{ .rank = 1, .file = 4 },
        .to = .{ .rank = 3, .file = 4 },
    };
    try game.play_move(mv);

    try std.testing.expectEqual(.empty, game.board.board_state[1][4]);
    try std.testing.expectEqual(.white_pawn, game.board.board_state[3][4]);
    try std.testing.expectEqual(Color.black, game.turn);
    // Double push registers the passed-over square (e3) as the en-passant target.
    try std.testing.expectEqual(Position{ .rank = 2, .file = 4 }, game.en_passant_square.?);
}

test "play_move returns InvalidMove when source square is empty" {
    var game: Game = undefined;
    game.init(.white);

    // e4 is empty on the starting board.
    const mv = Move{
        .from = .{ .rank = 3, .file = 4 },
        .to = .{ .rank = 4, .file = 4 },
    };
    try std.testing.expectError(error.InvalidMove, game.play_move(mv));
}

test "play_move: black plays en-passant after white double-push, victim removed and recorded" {
    // Minimal fixture: both kings + the two pawns involved. Goes through the full game
    // state machine — preview_move detects en-passant, apply_effect removes the victim
    // and appends to captures_by_black, the trailing switch clears the ep window.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_pawn, .{ .rank = 1, .file = 4 }); // e2
    test_util.place(&game.board, .black_pawn, .{ .rank = 3, .file = 3 }); // d4

    // 1. e2-e4 — double push, sets ep target to e3 = (2, 4).
    try game.play_move(.{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } });
    try std.testing.expectEqual(Position{ .rank = 2, .file = 4 }, game.en_passant_square.?);

    // 1... d4xe3 e.p. — black diagonal capture onto the (empty) ep target square; the
    // victim white pawn physically sits on e4 = (3, 4) and must be cleared.
    try game.play_move(.{ .from = .{ .rank = 3, .file = 3 }, .to = .{ .rank = 2, .file = 4 } });

    try std.testing.expectEqual(Piece.empty, game.board.board_state[3][4]); // e4 victim removed
    try std.testing.expectEqual(Piece.empty, game.board.board_state[3][3]); // d4 source empty
    try std.testing.expectEqual(Piece.black_pawn, game.board.board_state[2][4]); // e3 ep destination
    try std.testing.expectEqual(@as(usize, 1), game.captures_by_black.len);
    try std.testing.expectEqual(Piece.white_pawn, game.captures_by_black.slice()[0]);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_white.len);
    try std.testing.expectEqual(@as(?Position, null), game.en_passant_square);
    try std.testing.expectEqual(Color.white, game.turn);
}

test "play_move: regular capture appends the victim to captures_by_<turn>" {
    // Confirms the new MoveEffect.capture → Game.append_captured_piece plumbing actually
    // populates the per-side captures list when a capturing move flows through play_move.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 0 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 7 });
    test_util.place(&game.board, .white_rook, .{ .rank = 3, .file = 4 }); // e4
    test_util.place(&game.board, .black_pawn, .{ .rank = 5, .file = 4 }); // e6

    // White rook e4 → e6, captures black pawn.
    try game.play_move(.{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 5, .file = 4 } });

    try std.testing.expectEqual(@as(usize, 1), game.captures_by_white.len);
    try std.testing.expectEqual(Piece.black_pawn, game.captures_by_white.slice()[0]);
    try std.testing.expectEqual(@as(usize, 0), game.captures_by_black.len);
    try std.testing.expectEqual(Piece.white_rook, game.board.board_state[5][4]);
    try std.testing.expectEqual(Piece.empty, game.board.board_state[3][4]);
}

test "play_move: en_passant_square clears after a non-double-push reply to a double push" {
    // Regression guard for the trailing switch in apply_effect — drop the `else => null`
    // arm and a stale ep target survives indefinitely. Two-move sequence (1. e4, 1... a6)
    // proves the clear leg fires for any non-double-push effect.
    var game: Game = undefined;
    game.init(.white);

    // 1. e4 — sets ep target to e3.
    try game.play_move(.{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } });
    try std.testing.expectEqual(Position{ .rank = 2, .file = 4 }, game.en_passant_square.?);

    // 1... a6 — black single push, must clear the ep window.
    try game.play_move(.{ .from = .{ .rank = 6, .file = 0 }, .to = .{ .rank = 5, .file = 0 } });
    try std.testing.expectEqual(@as(?Position, null), game.en_passant_square);
}

test "play_move: white kingside castling moves king + rook and clears both white rights" {
    // End-to-end: preview_move → apply_effect (castling arm moves the rook) → castling_rights_after
    // clears both white flags. Black rights must be untouched.
    var game: Game = undefined;
    game.init(.white);
    game.board = test_util.empty_board();
    test_util.place(&game.board, .white_king, .{ .rank = 0, .file = 4 });
    test_util.place(&game.board, .white_rook, .{ .rank = 0, .file = 7 });
    test_util.place(&game.board, .black_king, .{ .rank = 7, .file = 0 });

    try game.play_move(.{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 6 } });

    try std.testing.expectEqual(Piece.white_king, game.board.board_state[0][6]);
    try std.testing.expectEqual(Piece.white_rook, game.board.board_state[0][5]);
    try std.testing.expectEqual(Piece.empty, game.board.board_state[0][4]);
    try std.testing.expectEqual(Piece.empty, game.board.board_state[0][7]);
    try std.testing.expect(!game.castling_rights.white_kingside);
    try std.testing.expect(!game.castling_rights.white_queenside);
    try std.testing.expect(game.castling_rights.black_kingside);
    try std.testing.expect(game.castling_rights.black_queenside);
    try std.testing.expectEqual(Color.black, game.turn);
    try std.testing.expectEqual(@as(?Position, null), game.en_passant_square);
}

// Pulls the whole rule engine into the test runner. A normal `@import` (see the top of this
// file) forces *analysis* but not test discovery; the `_ = @import` form inside a test block
// is what adds a file's `test` blocks to the running binary.
test {
    _ = @import("rule_engine/rules.zig");
    _ = @import("rule_engine/check_helper.zig");
    _ = @import("rule_engine/shared.zig");
    _ = @import("rule_engine/test_util.zig");
}
