const std = @import("std");
const state_machines = @import("state_machines");
const terminal_io = @import("terminal_io.zig");
const board_mod = @import("board.zig");
const board_renderer = @import("board_renderer.zig");
const Position = @import("shared.zig").Position;

var board: board_mod.Board = undefined;
var renderer: board_renderer.BoardRenderer = undefined;

fn handle_resize(new_ws: std.posix.winsize) void {
    renderer.resize(new_ws) catch return;
    const buf = renderer.draw(&board) catch return;
    _ = terminal_io.TerminalIO.write(buf);
}

pub fn main() !void {
    var io: terminal_io.TerminalIO = undefined;
    try io.init();
    try io.enable_raw_mode();
    defer io.restore_termios();

    board.init();
    try renderer.init(io.window_config);

    const buffer = try renderer.draw(&board);
    _ = terminal_io.TerminalIO.write(buffer);

    const moves = [_][2]Position{
        .{ .{ .rank = 1, .file = 3 }, .{ .rank = 3, .file = 3 } },
        .{ .{ .rank = 6, .file = 3 }, .{ .rank = 4, .file = 3 } },
        .{ .{ .rank = 1, .file = 2 }, .{ .rank = 3, .file = 2 } },
        .{ .{ .rank = 6, .file = 4 }, .{ .rank = 5, .file = 4 } },
        .{ .{ .rank = 0, .file = 1 }, .{ .rank = 2, .file = 2 } },
        .{ .{ .rank = 7, .file = 6 }, .{ .rank = 5, .file = 5 } },
    };

    for (moves) |move| {
        _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 0 }, null);
        board.move(move[0], move[1]);
        renderer.flip_perspective();
        const buf = try renderer.draw(&board);
        _ = terminal_io.TerminalIO.write(buf);
    }

    try io.start_input_loop(handle_resize);
}
