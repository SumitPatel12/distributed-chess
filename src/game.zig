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
const Piece = board_mod.Piece;
const rules_engine = @import("rule_engine/rules.zig");

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

/// The piece a pawn is promoted to on reaching the final rank. A restricted subset of Piece —
/// kings and pawns can't be promotion targets, and the color is determined by the mover.
pub const PromotionPiece = enum {
    queen,
    rook,
    bishop,
    knight,
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
    current_turn: Color,

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
            .current_turn = .white,
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
    /// the captures. Returns error.IllegalMove in case the move is illegal.
    pub fn play_move(self: *Game, move: Move) !void {
        if (!self.is_move_legal(move)) {
            return error.InvalidMove;
        }

        // TODO: Handle special captures. Like en-passant
        const captured_piece = self.board.board_state[move.to.rank][move.to.file];

        // Handle captures.
        if (captured_piece != .empty) {
            // You can't capture your own piece and you can't captrue a king.
            std.debug.assert(captured_piece.color().? != self.current_turn);
            std.debug.assert(captured_piece != .white_king and captured_piece != .black_king);

            switch (self.current_turn) {
                .white => self.captures_by_white.append_assume_capacity(captured_piece),
                .black => self.captures_by_black.append_assume_capacity(captured_piece),
            }
        }

        // Update the board position and flip the turn color.
        self.board.move(move.from, move.to);
        // TODO: This should likely be something a game effect would enforce, not sure, keeping
        // as is for now for testing purposes.
        self.current_turn = switch (self.current_turn) {
            .black => .white,
            .white => .black,
        };
    }

    /// Returns true if `move` is a legal move given the current board, castling rights, and
    /// en-passant square. Pure query — does not mutate game state. Turn check is the caller's
    /// responsibility.
    pub fn is_move_legal(self: *const Game, move: Move) bool {
        return rules_engine.is_legal_piece_move(&self.board, &self.castling_rights, self.en_passant_square, move);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

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

// Pulls the whole rule engine into the test runner. A normal `@import` (see the top of this
// file) forces *analysis* but not test discovery; the `_ = @import` form inside a test block
// is what adds a file's `test` blocks to the running binary.
test {
    _ = @import("rule_engine/rules.zig");
    _ = @import("rule_engine/check_helper.zig");
    _ = @import("rule_engine/shared.zig");
    _ = @import("rule_engine/test_util.zig");
}

test "is_move_legal accepts e2-e4 from the starting position" {
    var game: Game = undefined;
    game.init(.white);

    const mv = Move{
        .from = .{ .rank = 1, .file = 4 },
        .to = .{ .rank = 3, .file = 4 },
    };
    try std.testing.expect(game.is_move_legal(mv));
}

test "is_move_legal rejects e2-e5 from the starting position" {
    var game: Game = undefined;
    game.init(.white);

    // Triple-push is never legal.
    const mv = Move{
        .from = .{ .rank = 1, .file = 4 },
        .to = .{ .rank = 4, .file = 4 },
    };
    try std.testing.expect(!game.is_move_legal(mv));
}

test "is_move_legal rejects a move whose from square is empty" {
    var game: Game = undefined;
    game.init(.white);

    // e4 is empty on the starting board.
    const mv = Move{
        .from = .{ .rank = 3, .file = 4 },
        .to = .{ .rank = 4, .file = 4 },
    };
    try std.testing.expect(!game.is_move_legal(mv));
}

test "is_move_legal rejects a move that would leave own king in check" {
    // Pin scenario: white king d1, white rook d2 (pinned on the d-file), black rook d8. The
    // pinned rook's only legal squares are along the pin ray; moving off the d-file exposes
    // the king to the attacker.
    var game: Game = undefined;
    game.init(.white);

    // Clear the starting position down to just the pin setup.
    game.board.board_state = .{.{.empty} ** 8} ** 8;
    game.board.board_state[0][3] = .white_king; // d1
    game.board.board_state[1][3] = .white_rook; // d2
    game.board.board_state[7][3] = .black_rook; // d8
    // Black king must exist too — `filter_self_check` runs `in_check` for the side to move,
    // but also relies on a legal board (both kings present).
    game.board.board_state[7][7] = .black_king;
    game.board.king_pos = .{
        .{ .rank = 0, .file = 3 }, // white king d1
        .{ .rank = 7, .file = 7 }, // black king h8
    };

    // Pinned rook tries to leave the d-file (d2 → e2) — illegal.
    const illegal = Move{
        .from = .{ .rank = 1, .file = 3 },
        .to = .{ .rank = 1, .file = 4 },
    };
    try std.testing.expect(!game.is_move_legal(illegal));
}
