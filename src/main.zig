const std = @import("std");
const state_machines = @import("state_machines");
const terminal_io = @import("terminal_io.zig");
const chess_board = @import("chess_board.zig");
const Position = chess_board.Position;

pub fn main() !void {
    var term = try terminal_io.TerminalIO.init();
    try term.enable_raw_mode();
    defer term.restore_termios();

    var board = try chess_board.Board.init_board(term.window_config);
    try board.draw();

    const moves = [_][2]Position{
        .{ .{ .rank = 1, .file = 3 }, .{ .rank = 3, .file = 3 } },
        .{ .{ .rank = 6, .file = 3 }, .{ .rank = 4, .file = 3 } },
        .{ .{ .rank = 1, .file = 2 }, .{ .rank = 3, .file = 2 } },
        .{ .{ .rank = 6, .file = 4 }, .{ .rank = 5, .file = 4 } },
        .{ .{ .rank = 0, .file = 1 }, .{ .rank = 2, .file = 2 } },
        .{ .{ .rank = 7, .file = 6 }, .{ .rank = 5, .file = 5 } },
    };

    for (moves) |move| {
        // Sleep for 3 seconds before making each move.
        _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
        try board.move(move[0], move[1]);
    }

    try term.start_input_loop();
}
