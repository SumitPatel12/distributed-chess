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
    empty = 0,
    white_pawn = 1,
    white_knight = 2,
    white_bishop = 3,
    white_rook = 4,
    white_queen = 5,
    white_king = 6,
    black_pawn = -1,
    black_knight = -2,
    black_bishop = -3,
    black_rook = -4,
    black_queen = -5,
    black_king = -6,

    /// Returns the UTF-8 glyph for this piece. Both colors use the filled
    /// (solid) glyph set — the U+265A..F range — and colors are distinguished
    /// by foreground SGR instead of outline-vs-filled. Empty renders as a
    /// space so it can be dropped into the render buffer directly.
    pub fn glyph(self: Piece) []const u8 {
        return switch (self) {
            .empty => " ",
            .white_pawn, .black_pawn => "\u{265F}",
            .white_knight, .black_knight => "\u{265E}",
            .white_bishop, .black_bishop => "\u{265D}",
            .white_rook, .black_rook => "\u{265C}",
            .white_queen, .black_queen => "\u{265B}",
            .white_king, .black_king => "\u{265A}",
        };
    }

    /// Returns the foreground SGR sequence that should precede the glyph for
    /// this piece. Empty returns "" since nothing is drawn.
    pub fn fg(self: Piece) []const u8 {
        return switch (self) {
            .empty => "",
            .white_pawn, .white_knight, .white_bishop, .white_rook, .white_queen, .white_king => WHITE_PIECE_FG,
            .black_pawn, .black_knight, .black_bishop, .black_rook, .black_queen, .black_king => BLACK_PIECE_FG,
        };
    }
};

/// Perspective that drives how the board will be rendered on the screen.
/// Whichever is selected will be rendered towards the user, i.e. if perspective was white then
/// black would be on the top of the screen and white would be on the bottom, and vice-versa for
/// when the perspective is black.
pub const Perspective = enum {
    white,
    black,
};

/// Position of a piece on the board (rank, file).
pub const Position = struct {
    rank: u3,
    file: u3,
};

// The height and width of the cells are required to calculate the padding needed to apply to each cell when rendering, otherwise the pieces won't be centered.
/// Encodes the current board.
/// Keeps track of the board state, overlays if any. Also keeps track of the current boards cell width and height in terms of terminal cells.
pub const Board = struct {
    /// Current State of the board with piece positions.
    /// Row 0 is black's back rank and row 7 is white's back rank.
    board_state: [8][8]Piece,

    // This can likely be merged with board_state since it does have extra bits, that's an optimization I'll handle down the line.
    // 8x8 bits no need to waste so much space for this, each bit will represent whether that square is valid for that piece or not, at least that's what I'm aiming for.
    /// Highlights legal moves/squares once a piece is selected
    board_overlay: u64,

    /// Width of a single cell in terminal character columns.
    width: u16,

    /// Height of a single cell in terminal character rows.
    height: u16,

    /// The board state buffer writer owned by the board. Takes care of storing the byte sequence of the current board used to render it to the terminal.
    writer: BufWriter = .{},

    /// The perspective from which the board will be rendered. Defaults to White
    perspective: Perspective = .white,

    const LIGHT_BG = terminal_io.EscapeSequences.bg_rgb(184, 201, 134);
    const DARK_BG = terminal_io.EscapeSequences.bg_rgb(106, 138, 61);
    const RESET = terminal_io.EscapeSequences.RESET_STYLE_AND_COLOR;

    // TODO: Calculate a sane upper bound on this, right now it's too large. 256 KB is a lot.
    /// Upper bound on the rendered buffer size. Sized abnormally large so we can use the buffer without an allocator.
    const RENDER_BUFFER_SIZE: usize = 256 * 1024;

    // Chess board anatomy:
    //
    // Files run a..h left to right, ranks run 1..8 from white's side up to black's. A square is named
    // <file><rank> — e.g. the white king starts on e1, the black king on e8, and the move "e4" points at
    // the square shown in the middle of the diagram below. The bottom right corner of the board is always
    // a light square, irrespective of which players perspective you see from.
    //
    //                             BLACK
    //             a     b     c     d     e     f     g     h
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        8 | a8  | b8  | c8  | d8  | e8  | f8  | g8  | h8  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        7 | a7  | b7  | c7  | d7  | e7  | f7  | g7  | h7  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        6 | a6  | b6  | c6  | d6  | e6  | f6  | g6  | h6  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        5 | a5  | b5  | c5  | d5  | e5  | f5  | g5  | h5  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        4 | a4  | b4  | c4  | d4  | e4  | f4  | g4  | h4  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        3 | a3  | b3  | c3  | d3  | e3  | f3  | g3  | h3  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        2 | a2  | b2  | c2  | d2  | e2  | f2  | g2  | h2  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //        1 | a1  | b1  | c1  | d1  | e1  | f1  | g1  | h1  |
    //          +-----+-----+-----+-----+-----+-----+-----+-----+
    //             a     b     c     d     e     f     g     h
    //                             WHITE
    //
    // board_state is indexed as board_state[rank_idx][file_idx], with rank_idx 0 mapping to chess rank 1
    // (white's back rank) and rank_idx 7 to chess rank 8 (black's back rank). The array layout is flipped
    // vertically relative to the anatomy diagram above, so "e4" translates directly to board_state[3][4] —
    // no mental flip, rank_idx and chess rank line up exactly.
    //
    // I initially had this encoded as we see in the anatomy diagram above: for the 2D array, white sat at
    // the bottom (high rank_idx) and black at the top (low rank_idx). That inverted every rank lookup —
    // a pawn push from e2 -> e4 read as board_state[6][4] -> board_state[4][4] instead of the natural
    // board_state[1][4] -> board_state[3][4]. I'd be paying that translation cost at every call site for
    // white's position, and moves are what the whole game is built on, so I flipped the convention once
    // here rather than forever at every access.
    //
    // The two layouts, drawn as the 2D array sees them (rank_idx 0 on top, the way memory reads):
    //
    //              BEFORE (array matches the anatomy diagram,                     NOW (array is flipped — rank_idx lines
    //              but rank_idx is inverted vs chess rank):                       up with chess rank directly):
    //
    //                               BLACK                                                         WHITE
    //                a    b    c    d    e    f    g    h                         a    b    c    d    e    f    g    h
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 0 | a8 | b8 | c8 | d8 | e8 | f8 | g8 | h8 |          rank_idx 0 | a1 | b1 | c1 | d1 | e1 | f1 | g1 | h1 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 1 | a7 | b7 | c7 | d7 | e7 | f7 | g7 | h7 |          rank_idx 1 | a2 | b2 | c2 | d2 | e2 | f2 | g2 | h2 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 2 | a6 | b6 | c6 | d6 | e6 | f6 | g6 | h6 |          rank_idx 2 | a3 | b3 | c3 | d3 | e3 | f3 | g3 | h3 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 3 | a5 | b5 | c5 | d5 | e5 | f5 | g5 | h5 |          rank_idx 3 | a4 | b4 | c4 | d4 | e4 | f4 | g4 | h4 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 4 | a4 | b4 | c4 | d4 | e4 | f4 | g4 | h4 |          rank_idx 4 | a5 | b5 | c5 | d5 | e5 | f5 | g5 | h5 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 5 | a3 | b3 | c3 | d3 | e3 | f3 | g3 | h3 |          rank_idx 5 | a6 | b6 | c6 | d6 | e6 | f6 | g6 | h6 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 6 | a2 | b2 | c2 | d2 | e2 | f2 | g2 | h2 |          rank_idx 6 | a7 | b7 | c7 | d7 | e7 | f7 | g7 | h7 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //   rank_idx 7 | a1 | b1 | c1 | d1 | e1 | f1 | g1 | h1 |          rank_idx 7 | a8 | b8 | c8 | d8 | e8 | f8 | g8 | h8 |
    //              +----+----+----+----+----+----+----+----+                     +----+----+----+----+----+----+----+----+
    //                              WHITE                                                         BLACK
    //
    // Note how in BEFORE the array "looks right" (black on top, white on bottom like you'd set up a real
    // board) but rank_idx 0 = rank 8 and rank_idx 7 = rank 1 — every piece of move logic has to do
    // `8 - rank` to index white. In NOW the array is upside down compared to the physical board, but
    // rank_idx == (chess rank - 1), so the translation vanishes.
    //
    /// The starting position for a classical game. Sorted by rank and file so white side first.
    const STARTING_BOARD_POSITION: [8][8]Piece = .{
        .{ .white_rook, .white_knight, .white_bishop, .white_queen, .white_king, .white_bishop, .white_knight, .white_rook },
        .{.white_pawn} ** 8,
        .{.empty} ** 8,
        .{.empty} ** 8,
        .{.empty} ** 8,
        .{.empty} ** 8,
        .{.black_pawn} ** 8,
        .{ .black_rook, .black_knight, .black_bishop, .black_queen, .black_king, .black_bishop, .black_knight, .black_rook },
    };

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
            std.debug.assert(self.len <= self.buf.len);
        }

        /// Sets the next n bytes of the buffer to the provided byte value.
        /// In case of overflow returns RenderBufferOverflow error.
        fn write_byte_n(self: *BufWriter, byte: u8, n: usize) !void {
            if (self.len + n > self.buf.len) return error.RenderBufferOverflow;
            @memset(self.buf[self.len .. self.len + n], byte);
            self.len += n;
            std.debug.assert(self.len <= self.buf.len);
        }

        /// Returns the contents stored in the buffer up to the current length.
        fn written(self: *const BufWriter) []const u8 {
            std.debug.assert(self.len <= self.buf.len);
            return self.buf[0..self.len];
        }
    };

    // NOTE: Since this is initialized in-place make sure that all of the things that it calls
    // during the init also support in-place initialization.
    /// Initialize the board with the starting position and an empty board overlay.
    /// Initialization takes place in-place
    pub fn init(self: *Board, window_config: std.posix.winsize) !void {
        const dimensions = try compute_cell_dimensions(window_config);
        self.* = .{
            .board_state = STARTING_BOARD_POSITION,
            .board_overlay = 0,
            .width = dimensions.width,
            .height = dimensions.height,
            .writer = .{},
            .perspective = .white,
        };

        std.debug.assert(self.width >= 3);
        std.debug.assert(self.height >= 1);
        std.debug.assert(self.perspective == .white);
        std.debug.assert(self.board_overlay == 0);
        std.debug.assert(self.writer.len == 0);
    }

    /// Flips the perspective of the board. Doesn't redraw.
    /// Call `draw` after if you want the change to be immediately available. Generally piped
    /// with move, you'd move flip perspective and draw, so we batch two mutations.
    /// See `play_turn` for the common composite.
    pub fn flip_perspective(self: *Board) void {
        self.perspective = switch (self.perspective) {
            .white => .black,
            .black => .white,
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
        std.debug.assert(w >= 3 and h >= 1);
        std.debug.assert(w % 2 == 1 and h % 2 == 1);
        return .{ .width = w, .height = h };
    }

    /// Writes file letters (a..h) center aligned to cell width.
    fn write_file_labels(self: *Board) !void {
        std.debug.assert(self.width >= 3);

        try self.writer.write_all("   ");
        const padding: usize = (self.width - 1) / 2;
        const letters = switch (self.perspective) {
            .white => "abcdefgh",
            .black => "hgfedcba",
        };

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
        // The buffer will be build anew for each move, reset len just resets the current index/cursor of the buffer writer.
        // I thought this would not be good for performance, turns out I was wrong. The average times for writing the the buffer writer and rendering it to the screen are as below:
        // These values are of-course based on my machine which is a base M3 Pro.
        //      Buffer Write Time      : 65 µs
        //      Render To Terminal Time: 500 µs
        //
        // Sub milisecond times are not detectable by human eye. If you can, I think you're in the wrong career. You shouldn't be reading this code heh.
        self.writer.reset_len();
        std.debug.assert(self.writer.len == 0);

        const build_stats = try self.create_board_buffer();
        std.debug.assert(self.writer.len > 0);

        const write_start = timestamp_ns();
        const result_code = terminal_io.TerminalIO.write(self.writer.written());
        const write_ns = timestamp_ns() - write_start;

        if (result_code == -1) {
            std.debug.print("Failed to render to the terminal.", .{});
        }

        // These prints must come after the terminal write, because the buffer begins with
        // CLEAR_SCREEN — printing them before the write would put them on screen just long
        // enough to get wiped by the clear.
        const build = format_duration(build_stats.ns);
        std.debug.print("buffer build: {d} {s} ({d:.2} KB) | ", .{ build.value, build.unit, build_stats.size_kb });
        const write = format_duration(write_ns);
        std.debug.print("terminal write: {d} {s}\r\n", .{ write.value, write.unit });
    }

    fn create_board_buffer(self: *Board) !struct { ns: u64, size_kb: f64 } {
        std.debug.assert(self.width >= 3);
        std.debug.assert(self.height >= 1);

        const build_start = timestamp_ns();

        // Board row = 3-col side margin + 8 * w-col cells + 3-col side margin.
        // Centered 5-char label: (total - 5) / 2 spaces of left padding.
        const total_width: usize = 6 + 8 * self.width;
        // Min width is 3 so 6 + 8 * 3 = 30, at a bare minimun it's going to be 30
        std.debug.assert(total_width >= 30);
        const label_padding_len: usize = (total_width - 5) / 2;
        std.debug.assert(label_padding_len < total_width);
        const top_label = switch (self.perspective) {
            .white => "BLACK\r\n\r\n",
            .black => "WHITE\r\n\r\n",
        };
        const bottom_label = switch (self.perspective) {
            .white => "WHITE\r\n",
            .black => "BLACK\r\n",
        };

        try self.writer.write_all(terminal_io.EscapeSequences.CLEAR_SCREEN ++ terminal_io.EscapeSequences.SET_CURSOR_TO_HOME);
        try self.writer.write_byte_n(' ', label_padding_len);
        try self.writer.write_all(top_label);

        try self.write_file_labels();

        try self.write_rank_and_pieces();

        try self.write_file_labels();

        try self.writer.write_all("\r\n");
        try self.writer.write_byte_n(' ', label_padding_len);
        try self.writer.write_all(bottom_label);

        const size_kb = @as(f64, @floatFromInt(self.writer.len)) / 1024.0;
        const build_ns = timestamp_ns() - build_start;
        return .{ .ns = build_ns, .size_kb = size_kb };
    }

    /// Writes the rank labels and piece cells for the entire board, honoring the current
    /// perspective. Rank labels are the numbers 1 through 8 you see on the physical boards.
    ///
    /// The loop walks the board in *visual* order — (row_draw, col_draw) starts at the top-left
    /// of what the user sees and sweeps right-then-down. The mapping from visual position to
    /// board coordinates is the only thing that depends on perspective:
    ///   White: rank = 7 - row_draw, file = col_draw      (rank 8 on top, file a on left)
    ///   Black: rank = row_draw,     file = 7 - col_draw  (rank 1 on top, file h on left)
    fn write_rank_and_pieces(self: *Board) !void {
        std.debug.assert(self.width >= 3);
        std.debug.assert(self.height >= 1);

        const rank_margins = [_][]const u8{ " 1 ", " 2 ", " 3 ", " 4 ", " 5 ", " 6 ", " 7 ", " 8 " };

        const mid_sub: usize = self.height / 2;
        const padding: usize = (self.width - 1) / 2;

        for (0..8) |row_draw| {
            const rank: usize = switch (self.perspective) {
                .white => 7 - row_draw,
                .black => row_draw,
            };

            var sub_row: usize = 0;
            while (sub_row < self.height) : (sub_row += 1) {
                // Rank digit on the middle sub-row only, blank margin otherwise.
                const side_margin = if (sub_row == mid_sub) rank_margins[rank] else "   ";
                try self.writer.write_all(side_margin);

                for (0..8) |col_draw| {
                    const file: usize = switch (self.perspective) {
                        .white => col_draw,
                        .black => 7 - col_draw,
                    };

                    const piece = self.board_state[rank][file];
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

    /// Mutates `board_state` to move a piece from `from` to `to`. Doesn't re-draw, if you want the
    /// new state to be visible call the redraw function.
    /// See `play_turn` for the common composite.
    pub fn move(self: *Board, from: Position, to: Position) void {
        // Positions must refer to real squares on the board.
        std.debug.assert(from.rank < 8 and from.file < 8);
        std.debug.assert(to.rank < 8 and to.file < 8);
        // A move that doesn't change the square is not a move.
        std.debug.assert(from.rank != to.rank or from.file != to.file);

        const piece = self.board_state[from.rank][from.file];
        // Can't move a piece that isn't there.
        std.debug.assert(piece != .empty);

        self.board_state[from.rank][from.file] = .empty;
        self.board_state[to.rank][to.file] = piece;

        std.debug.assert(self.board_state[from.rank][from.file] == .empty);
        std.debug.assert(self.board_state[to.rank][to.file] == piece);
    }

    /// Mutates the board state, moves a piece from `from` to `to`. Flips the perspective and
    /// re-draws the board.
    pub fn play_turn(self: *Board, from: Position, to: Position) !void {
        self.move(from, to);
        self.flip_perspective();
        try self.draw();
    }
};
