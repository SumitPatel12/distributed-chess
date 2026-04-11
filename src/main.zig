const std = @import("std");
const state_machines = @import("state_machines");
const terminal_io = @import("terminal_io.zig");
const chess_board = @import("chess_board.zig");
const Position = chess_board.Position;

pub fn main() !void {
    var io = try terminal_io.TerminalIO.init();
    try io.enable_raw_mode();
    defer io.restore_termios();

    var board: chess_board.Board = undefined;
    try board.init(io.window_config);
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
        _ = std.c.nanosleep(&.{ .sec = 3, .nsec = 0 }, null);
        try board.play_turn(move[0], move[1]);
    }

    try io.start_input_loop();
}
