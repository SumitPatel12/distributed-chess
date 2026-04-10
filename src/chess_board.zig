const std = @import("std");
const terminal_io = @import("terminal_io.zig");

const WHITE_PIECE_FG = terminal_io.EscapeSequences.fg_rgb(255, 255, 255);
const BLACK_PIECE_FG = terminal_io.EscapeSequences.fg_rgb(0, 0, 0);

// White: ♔ U+2654   ♕ U+2655   ♖ U+2656   ♗ U+2657   ♘ U+2658   ♙ U+2659
// Black: ♚ U+265A   ♛ U+265B   ♜ U+265C   ♝ U+265D   ♞ U+265E   ♟ U+265F
//
// i8 because the board state needs to capture two things:
//  1. Piece Position
//  2. Piece Color
// Positive would be white and negative would be black. And since we only have 6 unique pieces i8 is more than enough.
/// Enum for pieces, the board_state will make use of this to encode the board state.
pub const Piece = enum(i8) {
    // I'll see if the bhishops need to be segregated into light_squared and dark_squared. For now I'll trust that the state_machine (or the move logic) eliminates the need for that.
    // I think this will be convenient, may be counterintuitive.
    Empty = 0,
    WhitePawn = 1,
    WhiteKnight = 2,
    WhiteBhishop = 3,
    WhiteRook = 4,
    WhiteQueen = 5,
    WhiteKing = 6,
    BlackPawn = -1,
    BlackKnight = -2,
    BlackBhishop = -3,
    BlackRook = -4,
    BlackQueen = -5,
    BlackKing = -6,

    /// Returns the UTF-8 glyph for this piece. Both colors use the filled
    /// (solid) glyph set — the U+265A..F range — and colors are distinguished
    /// by foreground SGR instead of outline-vs-filled. Empty renders as a
    /// space so it can be dropped into the render buffer directly.
    pub fn glyph(self: Piece) []const u8 {
        return switch (self) {
            .Empty => " ",
            .WhitePawn, .BlackPawn => "\u{265F}",
            .WhiteKnight, .BlackKnight => "\u{265E}",
            .WhiteBhishop, .BlackBhishop => "\u{265D}",
            .WhiteRook, .BlackRook => "\u{265C}",
            .WhiteQueen, .BlackQueen => "\u{265B}",
            .WhiteKing, .BlackKing => "\u{265A}",
        };
    }

    /// Returns the foreground SGR sequence that should precede the glyph for
    /// this piece. Empty returns "" since nothing is drawn.
    pub fn fg(self: Piece) []const u8 {
        return switch (self) {
            .Empty => "",
            .WhitePawn, .WhiteKnight, .WhiteBhishop, .WhiteRook, .WhiteQueen, .WhiteKing => WHITE_PIECE_FG,
            .BlackPawn, .BlackKnight, .BlackBhishop, .BlackRook, .BlackQueen, .BlackKing => BLACK_PIECE_FG,
        };
    }
};

pub const Position = struct {
    rank: usize,
    file: usize,
};

pub const Board = struct {
    /// Current State of the board with piece positions.
    /// Row 0 is black's back rank and row 7 is white's back rank.
    board_state: [8][8]Piece,

    // This can likely be merged with board_state since it does have extra bits, that's an optimization I'll handle down the line.
    // 8x8 bits no need to waste so much space for this, each bit will represent whether that square is valid for that piece or not, at least that's what I'm aiming for.
    /// Will encode move hints when a piece is selected.
    board_overlay: [8]u1,

    /// Width of a single cell in terminal character columns.
    width: usize,

    /// Height of a single cell in terminal character rows.
    height: usize,

    /// Render buffer writer owned by the board.
    writer: BufWriter = .{},

    // The bg_rgb and the fg_rgb always return 19 byte strings for convenience. If that changes we'll need to have two different variables to store each one.
    const COLOR_SEQUENCE_LENGTH = 19;
    const LIGHT_BG = terminal_io.EscapeSequences.bg_rgb(184, 201, 134);
    const DARK_BG = terminal_io.EscapeSequences.bg_rgb(106, 138, 61);
    const RESET = terminal_io.EscapeSequences.RESET_STYLE_AND_COLOR;

    // TODO: Calculate a sane upper bound on this, right now it's too large. 256 KB is a lot.
    /// Upper bound on the rendered buffer size. Sized abnormally large so we can use the buffer without an allocator.
    const RENDER_BUFFER_SIZE: usize = 256 * 1024;

    /// The starting position for a classical game
    const STARTING_BOARD_POSITION: [8][8]Piece = .{
        .{ .BlackRook, .BlackKnight, .BlackBhishop, .BlackQueen, .BlackKing, .BlackBhishop, .BlackKnight, .BlackRook },
        .{.BlackPawn} ** 8,
        .{.Empty} ** 8,
        .{.Empty} ** 8,
        .{.Empty} ** 8,
        .{.Empty} ** 8,
        .{.WhitePawn} ** 8,
        .{ .WhiteRook, .WhiteKnight, .WhiteBhishop, .WhiteQueen, .WhiteKing, .WhiteBhishop, .WhiteKnight, .WhiteRook },
    };

    const EMPTY_OVERLAY: [8]u1 = .{0} ** 8;

    /// Buffer writer to help draw the chess board on the terminal.
    const BufWriter = struct {
        buf: [RENDER_BUFFER_SIZE]u8 = undefined,
        /// Number of bytes currently held in `buf`; also the position where
        /// the next append will start.
        len: usize = 0,

        /// Resets the buffer length so it can be reused for the next draw.
        fn reset_len(self: *BufWriter) void {
            self.len = 0;
        }

        /// Appends bytes to the end of the buffer.
        /// In case of overflow returns RenderBufferOverflow error.
        fn write_all(self: *BufWriter, bytes: []const u8) !void {
            if (self.len + bytes.len > self.buf.len) return error.RenderBufferOverflow;
            @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
            self.len += bytes.len;
        }

        /// Sets the next n bytes of the buffer to the provided byte value.
        /// In case of overflow returns RenderBufferOverflow error.
        fn write_byte_n(self: *BufWriter, byte: u8, n: usize) !void {
            if (self.len + n > self.buf.len) return error.RenderBufferOverflow;
            @memset(self.buf[self.len .. self.len + n], byte);
            self.len += n;
        }

        /// Returns the contents stored in the buffer up to the current length.
        fn written(self: *const BufWriter) []const u8 {
            return self.buf[0..self.len];
        }
    };

    /// Initialize the board with the starting position and an emtpy board overlay.
    pub fn init_board(window_config: std.posix.winsize) !Board {
        const dimensions = try compute_cell_dimensions(window_config);
        return Board{
            .board_state = STARTING_BOARD_POSITION,
            .board_overlay = EMPTY_OVERLAY,
            .width = @as(usize, dimensions.width),
            .height = @as(usize, dimensions.height),
        };
    }

    /// Computes the per-cell width and height (in terminal character cells) for the largest chess board that fits in the current window.
    /// The Width to height aspect ratio is 7:3.
    /// Returns error.TerminalTooSmall if the window cannot fit the minimum 3x1 cell board.
    fn compute_cell_dimensions(ws: std.posix.winsize) !struct { width: u16, height: u16 } {
        // Horizontal overhead: 3-col rank margin on each side = 6 cols.
        // Vertical overhead: 2 file-letter rows + 2 title rows + 2 spacer rows = 6 rows.
        if (ws.col < 30 or ws.row < 14) return error.TerminalTooSmall;

        const avail_w: u16 = ws.col - 6;
        const avail_h: u16 = ws.row - 6;
        const max_w: u16 = avail_w / 8;
        const max_h: u16 = avail_h / 8;

        // 7:3 cell aspect ratio (7 cols x 3 rows).
        const h_from_w: u16 = (max_w * 3) / 7;
        var h: u16 = if (max_h < h_from_w) max_h else h_from_w;
        var w: u16 = (h * 7) / 3;

        // Round down to odd so the single glyph row/column lands on center.
        if (w % 2 == 0) w -= 1;
        if (h % 2 == 0) h -= 1;

        if (w < 3 or h < 1) return error.TerminalTooSmall;
        return .{ .width = w, .height = h };
    }

    /// Taken in the rank and file and returns the cells width in bytes.
    /// Used to offset into a certain cell and update the contents when moving from one position to another.
    fn get_cell_width_bytes(self: *Board, rank: usize, file: usize) usize {
        return switch (self.board_state[rank][file]) {
            .Empty => COLOR_SEQUENCE_LENGTH + self.width,
            // It's got both bg and fg so 2xclr_sq_len, and it's got width - 1 padding and a 3 byte glyph
            else => (COLOR_SEQUENCE_LENGTH * 2) + (self.width - 1) + 3,
        };
    }

    /// Writes file letters (a..h) center aligned to cell width.
    fn write_file_labels(self: *Board) !void {
        try self.writer.write_all("   ");
        const padding: usize = (self.width - 1) / 2;
        const letters = "abcdefgh";
        for (letters) |ch| {
            try self.writer.write_byte_n(' ', padding);
            try self.writer.write_all(&[_]u8{ch});
            try self.writer.write_byte_n(' ', padding);
        }
        try self.writer.write_all("\r\n");
    }

    /// Returns a monotonic timestamp in nanoseconds.
    /// Uses std.c.clock_gettime which is Zig's cross-platform libc wrapper.
    /// The clock choice adapts per OS: UPTIME_RAW on macOS, MONOTONIC on Linux.
    fn timestamp_ns() u64 {
        const clock = if (@hasField(std.c.CLOCK, "UPTIME_RAW")) .UPTIME_RAW else .MONOTONIC;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(clock, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    fn format_duration(ns: u64) struct { value: u64, unit: []const u8 } {
        if (ns >= 1_000_000) return .{ .value = ns / 1_000_000, .unit = "ms" };
        if (ns >= 1_000) return .{ .value = ns / 1_000, .unit = "µs" };
        return .{ .value = ns, .unit = "ns" };
    }

    /// Draws the current board state to the terminal
    pub fn draw(self: *Board) !void {
        self.writer.reset_len();
        const build_start = timestamp_ns();

        // Board row = 3-col side margin + 8 * w-col cells + 3-col side margin.
        // Centered 5-char label: (total - 5) / 2 spaces of left padding.
        const total_width: usize = 6 + 8 * self.width;
        const label_padding_len: usize = (total_width - 5) / 2;

        try self.writer.write_all(terminal_io.EscapeSequences.CLEAR_SCREEN ++ terminal_io.EscapeSequences.SET_CURSOR_TO_HOME);
        try self.writer.write_byte_n(' ', label_padding_len);
        try self.writer.write_all("BLACK\r\n\n\r");

        try self.write_file_labels();

        try self.write_rank_and_pieces();

        try self.write_file_labels();

        try self.writer.write_all("\r\n");
        try self.writer.write_byte_n(' ', label_padding_len);
        try self.writer.write_all("WHITE\r\n");

        const build_ns = timestamp_ns() - build_start;

        const write_start = timestamp_ns();
        const result_code = terminal_io.TerminalIO.write(self.writer.written());
        const write_ns = timestamp_ns() - write_start;

        if (result_code == -1) {
            std.debug.print("Failed to render to the terminal.", .{});
        }

        const build = format_duration(build_ns);
        const write = format_duration(write_ns);
        const size_kb = @as(f64, @floatFromInt(self.writer.len)) / 1024.0;
        std.debug.print("buffer build: {d} {s} ({d:.2} KB) | terminal write: {d} {s}\r\n", .{
            build.value, build.unit, size_kb,
            write.value, write.unit,
        });
    }

    fn write_rank_and_pieces(self: *Board) !void {
        // Left-edge rank labels. Index 0 is the black back rank (chess rank 8).
        const rank_margins = [_][]const u8{ " 8 ", " 7 ", " 6 ", " 5 ", " 4 ", " 3 ", " 2 ", " 1 " };

        const mid_sub: usize = self.height / 2;
        const padding: usize = (self.width - 1) / 2;

        for (self.board_state, 0..) |rank_row, rank| {
            var sub_row: usize = 0;
            while (sub_row < self.height) : (sub_row += 1) {
                // Rank digit on the middle sub-row only, blank margin otherwise.
                const side_margin = if (sub_row == mid_sub) rank_margins[rank] else "   ";
                try self.writer.write_all(side_margin);

                for (rank_row, 0..) |piece, file| {
                    const bg = if ((rank + file) % 2 == 0) LIGHT_BG else DARK_BG;
                    try self.writer.write_all(bg);
                    // Middle row holds the glyph with some padding to center it
                    if (sub_row == mid_sub) {
                        try self.writer.write_byte_n(' ', padding);
                        try self.writer.write_all(piece.fg());
                        try self.writer.write_all(piece.glyph());
                        try self.writer.write_byte_n(' ', padding);
                    } else {
                        try self.writer.write_byte_n(' ', self.width);
                    }
                }

                // The labeling is on both sides.
                try self.writer.write_all(RESET);
                try self.writer.write_all(side_margin);
                try self.writer.write_all("\r\n");
            }
        }
    }

    pub fn move(self: *Board, old_position: Position, new_position: Position) void {
        const piece = self.board_state[old_position.rank][old_position.file];
        std.debug.assert(piece != .Empty);

        self.board_state[old_position.rank][old_position.file] = .Empty;
        self.board_state[new_position.rank][new_position.file] = piece;
    }
};
