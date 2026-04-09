const std = @import("std");
const state_machines = @import("state_machines");
const terminal_io = @import("terminal_io.zig");
const chess_board = @import("chess_board.zig");

pub fn main() !void {
    var term = try terminal_io.TerminalIO.init();
    try term.enable_raw_mode();
    defer term.restore_termios();

    var board = try chess_board.Board.init_board(term.window_config);
    try board.draw();

    try term.start_input_loop();
}
