const std = @import("std");
const state_machines = @import("state_machines");
// At the start the original termios won't be set of-course

pub fn main() !void {
    const original_termios = try enable_raw_mode();
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.FLUSH, original_termios) catch {
        std.debug.print("Error resetting the termios settings.", .{});
        // Nothing we can do, the user will have to re-open the terminal.
    };

    // Not particularly useful right now but will be used when we render the board and start accepting user input.
    // This will likely move out of this file into it's own thing at some point.
    while (true) {
        var c: u8 = 0;
        while (true) {
            const nread = std.posix.read(std.posix.STDIN_FILENO, (&c)[0..1]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    // std.process.exit(x) doesn't let zig cleanup run before the program terminates, effectively leaving the calling terminal window in raw mode,
                    // so we're not gonna use that.
                    std.debug.print("Error encountered while reading from STDIN_FILENO", .{});
                    return;
                },
            };

            if (nread == 1) {
                break;
            }
        }

        switch (c) {
            'q' => {
                std.debug.print("Good Bye!", .{});
                return;
            },
            '\x1b' => {
                std.debug.print("User Pressed Escape\r\n", .{});
            },
            else => {
                std.debug.print("Read the Character: {c}\r\n", .{c});
            },
        }
    }
}

fn enable_raw_mode() !std.posix.termios {
    const original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw_mode_termios: std.posix.termios = original_termios;

    // IXON: Disables Ctrl-S and Ctrl-Q. Ctrl-S stops data from being transmitted
    // to the terminal until you press Ctrl-Q
    //
    // ICRNL: Disables Ctrl-M. Ctrl-M should return 13, but it returns 10. The
    // terminal translates any carriage returns (13, '\r') inputted by the user
    // into newlines (10, '\n').
    //
    // IBRKINT: Break conditons cause SIGINT
    //
    // INPCK: Enables parity checking, mostly doesn't apply to modern computers.
    //
    // ISTRIP: causes the 8th bit of each input byte to be stripped (setting it to
    // 0). It's probably turned off for modern terminals.
    raw_mode_termios.iflag.IXON = false;
    raw_mode_termios.iflag.ICRNL = false;
    raw_mode_termios.iflag.BRKINT = false;
    raw_mode_termios.iflag.INPCK = false;
    raw_mode_termios.iflag.ISTRIP = false;

    // Turns off all output processing. Output processing changes all "\n" to
    // "\r\n".
    // "\n" moves the cursor to the next line, and \r moves it back to the start
    // of that line.
    // For example: If the cursor was at position represented by (row, col): (5,
    // 10).
    // \n will make the new position (6, 10).
    // \r will make the new position (6, 0).
    raw_mode_termios.oflag.OPOST = false;

    // Set the character size to 8 bits
    raw_mode_termios.cflag.CSIZE = .CS8;

    // VMIN: Minimum number of characters for noncanonical read (VMIN).
    // 0 means we return as soon as any input to be read.
    raw_mode_termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;

    // VTIME: Timeout in deciseconds for noncanonical read (TIME).
    // Returns 0 after 0.1 x n seconds n begin the value provided.
    raw_mode_termios.cc[@intFromEnum(std.posix.V.TIME)] = 1;

    // c_lflag is for the local flags.
    //
    // ECHO: Causes each key press to be printed to the terminal, it's good for
    // when you're in canonical mode, but in raw mode you don't want the user's
    // input echoed since you're gonig to be handling that.
    //
    // ICANON is for canonical mode. In that mode, inupt is made visible line by
    // line.
    //
    // ISIG: When any of the characters INTR, QUIT, SUSP, or DSUSP are received,
    // generate the corresponding signal.
    // Unsetting ISIG stops the signals Ctrl-C and Ctrl-Z
    //
    // IEXTEN: Turns off Ctrl-V, and Ctrl-O
    raw_mode_termios.lflag.ECHO = false;
    raw_mode_termios.lflag.ICANON = false;
    raw_mode_termios.lflag.ISIG = false;
    raw_mode_termios.lflag.IEXTEN = false;

    try std.posix.tcsetattr(std.posix.STDIN_FILENO, std.posix.TCSA.FLUSH, raw_mode_termios);
    return original_termios;
}
