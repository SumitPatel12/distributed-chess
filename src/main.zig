//! Handles creating the game, running the input loop and orchestrating the side-effects from the
//! state machine that is the game.

const std = @import("std");
const state_machines = @import("state_machines");
const terminal_io = @import("terminal_io.zig");
const game_mod = @import("game.zig");
const board_renderer = @import("board_renderer.zig");

const Game = game_mod.Game;
const BoardRenderer = board_renderer.BoardRenderer;

test {
    _ = @import("game.zig");
    _ = @import("bounded_array.zig");
    _ = @import("zobrist_table.zig");
    _ = @import("board.zig");
    _ = @import("shared.zig");
    _ = @import("board_renderer.zig");
    _ = @import("terminal_io.zig");
}

pub fn main() !void {
    var io: terminal_io.TerminalIO = undefined;
    try io.init();
    try io.enable_raw_mode();
    defer io.restore_termios();

    var game: Game = undefined;
    game.init(.white);
    std.debug.assert(game.player_color == .white);

    var renderer: BoardRenderer = undefined;
    renderer.init(io.window_config);

    const write_result = io.write(renderer.draw(&game));

    if (write_result == -1) {
        std.debug.print("Error rendering board.", .{});
    }
}
