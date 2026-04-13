const std = @import("std");
const terminal_io = @import("terminal_io.zig");
const board_mod = @import("board.zig");
const Piece = board_mod.Piece;
const Board = board_mod.Board;
const Color = @import("shared.zig").Color;
const BoundedArray = @import("bounded_array.zig").BoundedArray;

pub const BoardRenderer = struct {
    // 8x8 bits, each bit represents whether that square is valid for the selected piece or not.
    /// Highlights legal moves/squares once a piece is selected
    board_overlay: u64,

    /// Width of a single cell in terminal character columns.
    width: u16,

    /// Height of a single cell in terminal character rows.
    height: u16,

    /// Buffer for building the rendered board frame. Takes care of storing the byte sequence
    /// used to render the board to the terminal.
    writer: BoundedArray(u8, RENDER_BUFFER_SIZE) = .{},

    /// The perspective from which the board will be rendered. Defaults to White.
    /// Whichever is selected will be drawn on the lower side of the screen.
    perspective: Color = .white,

    const LIGHT_BG = terminal_io.EscapeSequences.bg_rgb(184, 201, 134);
    const DARK_BG = terminal_io.EscapeSequences.bg_rgb(106, 138, 61);
    const RESET = terminal_io.EscapeSequences.RESET_STYLE_AND_COLOR;

    /// Upper bound on the rendered buffer size. With the largest cell size (11x5), worst case is
    /// ~12 KB. 16 KB gives comfortable headroom without an allocator.
    const RENDER_BUFFER_SIZE: usize = 16 * 1024;

    /// Allowed cell dimensions, ordered largest to smallest. compute_cell_dimensions picks the
    /// largest that fits the terminal. All widths and heights must be odd so the glyph lands on
    /// the center row/column.
    const ALLOWED_SIZES = [_]CellDimensions{
        .{ .width = 11, .height = 5 },
        .{ .width = 7, .height = 3 },
        .{ .width = 3, .height = 1 },
    };

    /// Per-cell dimensions in terminal character cells, as computed from the current window.
    const CellDimensions = struct {
        width: u16,
        height: u16,
    };

    pub fn init(self: *BoardRenderer, window_config: std.posix.winsize) !void {
        const dimensions = try compute_cell_dimensions(window_config);

        self.* = .{
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
    /// Call `draw` after if you want the change to be immediately available.
    pub fn flip_perspective(self: *BoardRenderer) void {
        self.perspective = switch (self.perspective) {
            .white => .black,
            .black => .white,
        };
    }

    /// Picks the largest allowed cell size that fits in the current terminal window.
    /// Returns error.TerminalTooSmall if even the smallest size doesn't fit.
    fn compute_cell_dimensions(ws: std.posix.winsize) !CellDimensions {
        // Horizontal overhead: 3-col rank margin on each side = 6 cols.
        // Vertical overhead: 2 file-letter rows + 2 title rows + 2 spacer rows = 6 rows.
        if (ws.col < 30 or ws.row < 14) {
            return error.TerminalTooSmall;
        }

        const max_w: u16 = (ws.col - 6) / 8;
        const max_h: u16 = (ws.row - 6) / 8;

        for (ALLOWED_SIZES) |size| {
            if (size.width <= max_w and size.height <= max_h) {
                return size;
            }
        }

        return error.TerminalTooSmall;
    }

    /// Re-computes cell dimensions after a terminal resize.
    pub fn resize(self: *BoardRenderer, window_config: std.posix.winsize) !void {
        const dimensions = try compute_cell_dimensions(window_config);
        self.width = dimensions.width;
        self.height = dimensions.height;

        std.debug.assert(self.width >= 3);
        std.debug.assert(self.height >= 1);
    }

    /// Writes file letters (a..h) center aligned to cell width.
    fn write_file_labels(self: *BoardRenderer) !void {
        std.debug.assert(self.width >= 3);

        try self.writer.append_slice("   ");
        const padding: usize = (self.width - 1) / 2;
        const letters = switch (self.perspective) {
            .white => "abcdefgh",
            .black => "hgfedcba",
        };

        for (letters) |ch| {
            try self.writer.append_n_times(' ', padding);
            try self.writer.append_slice(&[_]u8{ch});
            try self.writer.append_n_times(' ', padding);
        }
        try self.writer.append_slice("\r\n");
    }

    /// Builds the rendered board buffer and returns it. Caller writes it to the terminal.
    pub fn draw(self: *BoardRenderer, board: *const Board) ![]const u8 {
        // The buffer is built anew for each move, reset_len just resets the cursor of the buffer
        // writer. I thought this would not be good for performance, turns out I was wrong.
        //
        // Benchmark results (Apple M3 Pro, 18 GB, 500 iterations, 16 ms inter-frame delay,
        // 5.82 KB/frame):
        //      Buffer Build Time       : avg ~50 µs   (p99 ~92 µs)
        //      Terminal Write Time     : avg ~306 µs  (p99 ~587 µs)
        //      Total (build + write)   : avg ~356 µs  (p99 ~626 µs)
        //
        // The ~306 µs write cost is the real terminal I/O — pushing ~5.8 KB of escape sequences
        // through the pty. We run the benchmark with a 16ms delay in a loop to ensure each frame
        // does indeed get rendered. At least that's what I was hoping for.
        //
        // Sub millisecond times are not detectable by human eye. If you can, I think you're in the
        // wrong career. You shouldn't be reading this code heh.
        self.writer.reset();
        std.debug.assert(self.writer.len == 0);

        try self.create_board_buffer(board);
        std.debug.assert(self.writer.len > 0);
        return self.writer.slice();
    }

    fn create_board_buffer(self: *BoardRenderer, board: *const Board) !void {
        std.debug.assert(self.width >= 3);
        std.debug.assert(self.height >= 1);

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

        // Need to clear the scroll back otherwise if the window was scrolled and resized, then a
        // stale render of the previous board is still present at the top.
        const clear_and_home = terminal_io.EscapeSequences.CLEAR_SCREEN ++
            terminal_io.EscapeSequences.CLEAR_SCROLLBACK ++
            terminal_io.EscapeSequences.SET_CURSOR_TO_HOME;
        try self.writer.append_slice(clear_and_home);
        try self.writer.append_n_times(' ', label_padding_len);
        try self.writer.append_slice(top_label);

        try self.write_file_labels();

        try self.write_rank_and_pieces(board);

        try self.write_file_labels();

        try self.writer.append_slice("\r\n");
        try self.writer.append_n_times(' ', label_padding_len);
        try self.writer.append_slice(bottom_label);
    }

    /// Writes the rank labels and piece cells for the entire board, honoring the current
    /// perspective. Rank labels are the numbers 1 through 8 you see on the physical boards.
    ///
    /// The loop walks the board in *visual* order — (row_draw, col_draw) starts at the top-left
    /// of what the user sees and sweeps right-then-down. The mapping from visual position to
    /// board coordinates is the only thing that depends on perspective:
    ///   White: rank = 7 - row_draw, file = col_draw      (rank 8 on top, file a on left)
    ///   Black: rank = row_draw,     file = 7 - col_draw  (rank 1 on top, file h on left)
    fn write_rank_and_pieces(self: *BoardRenderer, board: *const Board) !void {
        std.debug.assert(self.width >= 3);
        std.debug.assert(self.height >= 1);

        const rank_margins = [_][]const u8{
            " 1 ",
            " 2 ",
            " 3 ",
            " 4 ",
            " 5 ",
            " 6 ",
            " 7 ",
            " 8 ",
        };

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

                try self.writer.append_slice(side_margin);

                for (0..8) |col_draw| {
                    const file: usize = switch (self.perspective) {
                        .white => col_draw,
                        .black => 7 - col_draw,
                    };

                    const piece = board.board_state[rank][file];
                    const bg = if ((rank + file) % 2 == 0) LIGHT_BG else DARK_BG;
                    try self.writer.append_slice(bg);
                    // Middle row holds the glyph with some padding to center it
                    if (sub_row == mid_sub) {
                        try self.writer.append_n_times(' ', padding);
                        try self.writer.append_slice(piece.fg());
                        try self.writer.append_slice(piece.glyph());
                        try self.writer.append_n_times(' ', padding);
                    } else {
                        try self.writer.append_n_times(' ', self.width);
                    }
                }

                // The labeling is on both sides.
                try self.writer.append_slice(RESET);
                try self.writer.append_slice(side_margin);
                try self.writer.append_slice("\r\n");
            }
        }
    }
};
