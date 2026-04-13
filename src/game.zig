const std = @import("std");
const board_mod = @import("board.zig");
const Color = @import("shared.zig").Color;
const Board = board_mod.Board;

pub const GameResult = enum {
    /// One of the players won by checkmating.
    checkmate,

    /// The position resulted in a stalemate.
    stalemate,

    /// One of the players resigned.
    resignation,

    // I'm not sure if I store who offered the draw, maybe a tagged enum?
    /// A player proposed a draw and the opponent accepted.
    draw_by_agreement,

    /// Represents a draw for when no player has moved a pawn or has captured any piece for 50 full
    /// moves
    draw_no_capture_or_pawn_move_fifty_move,

    /// Draw by three fold repetition, i.e. when the same position is reached thrice.
    draw_threefold_repetition,

    /// Draw due to insufficient material. Automatically applied when the game detects insufficient
    /// materials on the board.
    draw_insufficient_material,

    /// Awards the player a win if the opponnent disconnected and didn't reconnect for a certain
    /// period of time.
    disconnected,

    /// Both players disconnected and failed to reconnect, we declare that as a draw.
    disconnected_both,
};

/// It's this players turn.
pub const LocalTurn = enum {
    /// The player has yet to make a move.
    idle,

    /// The player has made his move and is waiting for acknowdgement from the opponent.
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
};

/// The state of the game. Can be playing, ended, or disconnected.
const GameState = union(enum) {
    /// The game is still ongoing.
    playing: Playing,

    /// One of the players is disconnected.
    paused_disconnected,

    /// Game is over with the result stored in the enum.
    game_over: GameResult,
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

    /// Counts the nubmer of half moves since the last capture or pawn move.
    /// Requred when one of the players want's to propose/claim a draw under the 50 move rule.
    halfmove_clock: u16,

    /// Game state, showing if playing, disconnected or ended.
    state: GameState,

    // TODO: Castling, en_passant, RSM Log, Piece Captured

    /// Initializes the Game struct in place.
    pub fn init(self: *Game, player_color: Color) void {
        self.* = .{
            .board = undefined,
            .state = initial_state(player_color),
            .current_color = .white,
            .halfmove_clock = 0,
            .fullmove_number = 1,
        };
        self.board.init();
    }

    /// Returns the initial game state based on the color of the pieces.
    pub fn initial_state(color: Color) GameState {
        switch (color) {
            .white => LocalTurn{.idle},
            .black => RemoteTurn{.waiting},
        }
    }

    // TODO: Add tick function, define LSM log, ack events.
};
