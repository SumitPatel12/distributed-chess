const std = @import("std");
const board_mod = @import("board.zig");
const BoundedArray = @import("bounded_array.zig").BoundedArray;
const shared = @import("shared.zig");
const Color = shared.Color;
const Board = board_mod.Board;
const Move = shared.Move;
const Position = shared.Position;
const Piece = board_mod.Piece;

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

// TODO: After understanding what is requied a bit more populate this struct.
const CastlingRights = struct {};

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
        switch (color) {
            .white => return GameState{ .playing = .{ .local_turn = .idle } },
            .black => return GameState{ .playing = .{ .remote_turn = .waiting } },
        }
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
        std.debug.assert(self.current_turn == .white);
        std.debug.assert(self.captures_by_black.len == 0);
        std.debug.assert(self.captures_by_white.len == 0);
        std.debug.assert(self.position_hash.len == 0);
        std.debug.assert(self.en_passant_square == null);
        std.debug.assert(self.expected_seq == 1);
    }

    /// The state machine with side effects. It reads the game event, mutates the state of the board
    /// and tracked state and returns the side-effects.
    ///
    /// For now invalid events will end in panic, will be handled down the line.
    pub fn tick(self: *Game, event: GameEvent) BoundedArray(GameEffect, MAX_EFFECTS) {
        // TODO: Wire up logic for each event
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
};
