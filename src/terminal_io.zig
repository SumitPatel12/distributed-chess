//! Sets the terminal in raw mode, keeps track of original termios settings, and declares the most
//! commonly used escape sequences. It also registers a window change call that helps re-render the
//! board when the window is resized.
//!
//! Also handles writing to the terminal as well.

const std = @import("std");

/// Struct containing the most common Escape Sequences for terminal commands.
/// Eg: Clear screen, erase line, set cursor to home and more.
pub const EscapeSequences = struct {
    pub const RESET_STYLE_AND_COLOR = "\x1b[0m";
    pub const ERASE_TILL_END_OF_SCREEN = "\x1b[0J";
    pub const ERASE_TILL_BEGINNING_OF_SCREEN = "\x1b[1J";
    pub const CLEAR_SCREEN = "\x1b[2J";
    pub const CLEAR_SCROLLBACK = "\x1b[3J";

    pub const ERASE_TILL_END_OF_LINE = "\x1b[0K";
    pub const ERASE_TILL_BEGINNING_OF_LINE = "\x1b[1K";
    pub const ERASE_ENTIRE_LINE = "\x1b[2K";
    pub const SET_CURSOR_TO_HOME = "\x1b[H";

    /// Returns an escape sequence that sets the background color to the provided rgb color.
    pub fn bg_rgb(comptime r: u8, comptime g: u8, comptime b: u8) []const u8 {
        return std.fmt.comptimePrint("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
    }

    /// Returns an escape sequence that sets the foreground color to the provided rgb color.
    pub fn fg_rgb(comptime r: u8, comptime g: u8, comptime b: u8) []const u8 {
        return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
    }
};

/// File-scope pointer to the TerminalIO instance's resize_pending flag.
/// Signal handlers are callconv(.c) and cannot access struct fields directly, so we bridge through
/// this pointer. Set during init(), cleared during restore_termios().
var resize_pending_ptr: ?*std.atomic.Value(bool) = null;

/// SIGWINCH handler sets a flag indicating resize is required.
fn handle_sigwinch(_: std.posix.SIG) callconv(.c) void {
    if (resize_pending_ptr) |ptr| {
        ptr.store(true, .release);
    }
}

/// Query current terminal window size via ioctl.
/// Returns null if the ioctl fails or returns zero dimensions.
fn query_winsize() ?std.posix.winsize {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(
        std.posix.STDOUT_FILENO,
        std.posix.T.IOCGWINSZ,
        &ws,
    );
    if (rc == -1) {
        return null;
    }

    if (ws.row == 0 or ws.col == 0) {
        return null;
    }

    return ws;
}

/// Struct to control terminal io.
/// Holds the current window config and the original termios setting to reset back to.
pub const TerminalIO = struct {
    /// The termios settings of the terminal at the time of initializing the TerminalIO struct.
    original_termios: std.posix.termios,

    /// The window configuration of the terminal at the time of initializing the TerminalIO struct.
    window_config: std.posix.winsize,

    /// Tracks whether or not this session is operating in raw mode or not.
    raw_mode_enabled: bool = false,

    /// Atomic flag set by the SIGWINCH handler when the terminal is resized.
    resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Initializes the TerminalIO struct in-place with the current termios and window config.
    /// Registers the SIGWINCH handler for terminal resize detection.
    pub fn init(self: *TerminalIO) !void {
        const original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        const window_config = query_winsize() orelse return error.WindowSizeUnavailable;

        self.* = .{
            .original_termios = original_termios,
            .window_config = window_config,
            .raw_mode_enabled = false,
        };

        std.debug.assert(self.window_config.row > 0 and self.window_config.col > 0);
        std.debug.assert(!self.raw_mode_enabled);

        // Wire up the file-scope pointer so the signal handler can reach our flag.
        resize_pending_ptr = &self.resize_pending;

        // SA.RESTART: auto-restart interrupted syscalls (e.g., read in the input loop)
        // after the signal, avoiding spurious EINTR handling.
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handle_sigwinch },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.WINCH, &act, null);
    }

    /// Enables raw mode input processing.
    pub fn enable_raw_mode(self: *TerminalIO) !void {
        std.debug.assert(!self.raw_mode_enabled);

        var raw_mode_termios: std.posix.termios = self.original_termios;

        // IXON: Disables Ctrl-S and Ctrl-Q. Ctrl-S stops data from being transmitted
        // to the terminal until you press Ctrl-Q
        //
        // ICRNL: Disables Ctrl-M. Ctrl-M should return 13, but it returns 10. The
        // terminal translates any carriage returns (13, '\r') inputted by the user
        // into newlines (10, '\n').
        //
        // IBRKINT: Break conditions cause SIGINT
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
        // input echoed since you're going to be handling that.
        //
        // ICANON is for canonical mode. In that mode, input is made visible line by
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

        try std.posix.tcsetattr(
            std.posix.STDIN_FILENO,
            std.posix.TCSA.FLUSH,
            raw_mode_termios,
        );
        self.raw_mode_enabled = true;

        std.debug.assert(self.raw_mode_enabled);
    }

    /// Restore the termios setting to the original termios settings.
    /// Deregisters the SIGWINCH handler.
    pub fn restore_termios(self: *TerminalIO) void {
        // Restore default SIGWINCH handling.
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.WINCH, &act, null);
        resize_pending_ptr = null;

        std.posix.tcsetattr(
            std.posix.STDIN_FILENO,
            std.posix.TCSA.FLUSH,
            self.original_termios,
        ) catch {
            std.debug.print("Error resetting the termios settings.", .{});
            // Nothing we can do, the user will have to re-open the terminal.
        };

        self.raw_mode_enabled = false;
        std.debug.assert(!self.raw_mode_enabled);
    }

    /// Checks if a terminal resize occurred since the last check. If so, re-queries the window size
    /// and updates window_config. Returns the new winsize, or null if no resize happened.
    pub fn check_resize(self: *TerminalIO) ?std.posix.winsize {
        // Atomically read and clear the flag in one operation, preventing a race where a second
        // SIGWINCH arrives between a separate load and store.
        if (self.resize_pending.swap(false, .acquire)) {
            if (query_winsize()) |ws| {
                self.window_config = ws;
                return ws;
            }
        }
        return null;
    }

    /// Callback invoked when the terminal is resized. Receives the new window size.
    pub const ResizeCallback = *const fn (std.posix.winsize) void;

    /// Starts an infinite loop of input reading. Reads character by character until the user
    /// inputs 'q', at which point the loop terminates.
    ///
    /// If `on_resize` is provided, it will be called whenever a terminal resize is detected,
    /// passing the new window dimensions.
    ///
    /// Requires the terminal to be in raw mode for this to work.
    pub fn start_input_loop(self: *TerminalIO, on_resize: ?ResizeCallback) !void {
        std.debug.assert(self.raw_mode_enabled);

        while (true) {
            if (self.check_resize()) |new_ws| {
                if (on_resize) |callback| {
                    callback(new_ws);
                }
            }

            var c: u8 = 0;
            const nread = std.posix.read(
                std.posix.STDIN_FILENO,
                (&c)[0..1],
            ) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    // std.process.exit(x) doesn't let zig cleanup run before the program terminates
                    // effectively leaving the calling terminal window in raw mode,
                    // so we're not gonna use that.
                    std.debug.print("Error encountered while reading from STDIN_FILENO", .{});
                    return;
                },
            };

            std.debug.assert(nread <= 1);

            // VMIN=0, VTIME=1 (set in enable_raw_mode) make read return after ~0.1s with or
            // without data. If nothing arrived we loop back and poll again.
            if (nread == 0) {
                continue;
            }

            switch (c) {
                'q' => {
                    std.debug.print("Good Bye!", .{});
                    return;
                },
                else => {
                    continue;
                },
            }
        }
    }

    /// Write out given buffer to the terminal.
    pub fn write(self: *const TerminalIO, buffer: []const u8) isize {
        _ = self;
        std.debug.assert(buffer.len > 0);
        return std.c.write(std.posix.STDOUT_FILENO, buffer.ptr, buffer.len);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

test "check_resize returns null when no resize pending and consumes the flag on read" {
    // We can test the pure atomic-flag logic by constructing a TerminalIO with
    // zeroed fields — check_resize only touches resize_pending and window_config,
    // both of which we set up here. No pty required.
    var io: TerminalIO = undefined;
    io.resize_pending = std.atomic.Value(bool).init(false);
    io.window_config = std.mem.zeroes(std.posix.winsize);

    // No resize pending → null.
    try std.testing.expectEqual(@as(?std.posix.winsize, null), io.check_resize());

    // Set the flag to simulate a SIGWINCH.
    io.resize_pending.store(true, .release);

    // check_resize will try query_winsize() which may fail in test (no tty), but the
    // flag must be consumed regardless. After this call it should be false.
    _ = io.check_resize();
    try std.testing.expectEqual(false, io.resize_pending.load(.acquire));
}
