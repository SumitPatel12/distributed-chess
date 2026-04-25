//! Takes in the Game struct and returns the byte sequence representing the current state of the
//! board.

const std = @import("std");
const terminal_io = @import("terminal_io.zig");
const shared = @import("shared.zig");
const game_mod = @import("game.zig");

const board_mod = @import("board.zig");
const Board = board_mod.Board;
const Piece = board_mod.Piece;
const Game = game_mod.Game;
const Color = shared.Color;
const BoundedArray = @import("bounded_array.zig").BoundedArray;

pub const BoardRenderer = struct {
    /// Rendering state. Cell dimensions live inside `.ok` so they can't be queried when the
    /// terminal is too small to hold a board; in the `.too_small` case we carry the offending
    /// window size so the fallback render can show the user how far off they are.
    state: State,

    /// Highlights legal moves/squares once a piece is selected
    board_overlay: u64,

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

    /// Minimum terminal columns to fit the smallest board (6-col side margins + 8 * 3-col cells).
    const MIN_COLS: u16 = 30;
    /// Minimum terminal rows to fit the smallest board (8 * 1-row cells + 2 file-letter rows +
    /// 2 title rows + 2 spacer rows).
    const MIN_ROWS: u16 = 14;

    // Currently these were pre-computed to work well on my machine with my font size and font.
    // Will likely think of a better solution down the line.
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

    const State = union(enum) {
        ok: CellDimensions,
        too_small: std.posix.winsize,
    };

    pub fn init(self: *BoardRenderer, window_config: std.posix.winsize) void {
        self.* = .{
            .state = resolve_state(window_config),
            .board_overlay = 0,
            .writer = .{},
            .perspective = .white,
        };

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

    /// Picks the largest allowed cell size that fits in the current terminal window, or null if
    /// even the smallest size doesn't fit.
    fn compute_cell_dimensions(ws: std.posix.winsize) ?CellDimensions {
        // Horizontal overhead: 3-col rank margin on each side = 6 cols.
        // Vertical overhead: 2 file-letter rows + 2 title rows + 2 spacer rows = 6 rows.
        if (ws.col < MIN_COLS or ws.row < MIN_ROWS) {
            return null;
        }
        std.debug.assert(ws.col >= MIN_COLS);
        std.debug.assert(ws.row >= MIN_ROWS);

        const max_w: u16 = (ws.col - 6) / 8;
        const max_h: u16 = (ws.row - 6) / 8;

        for (ALLOWED_SIZES) |size| {
            if (size.width <= max_w and size.height <= max_h) {
                return size;
            }
        }

        return null;
    }

    fn resolve_state(ws: std.posix.winsize) State {
        if (compute_cell_dimensions(ws)) |dims| {
            return .{ .ok = dims };
        }
        return .{ .too_small = ws };
    }

    /// Re-computes cell dimensions after a terminal resize.
    pub fn resize(self: *BoardRenderer, window_config: std.posix.winsize) void {
        self.state = resolve_state(window_config);
    }

    /// Writes file letters (a..h) center aligned to cell width.
    fn write_file_labels(self: *BoardRenderer, dims: CellDimensions) void {
        std.debug.assert(dims.width >= 3);

        self.writer.append_slice_assume_capacity("   ");
        const padding: usize = (dims.width - 1) / 2;
        const letters = switch (self.perspective) {
            .white => "abcdefgh",
            .black => "hgfedcba",
        };

        for (letters) |ch| {
            self.writer.append_n_times_assume_capacity(' ', padding);
            self.writer.append_slice_assume_capacity(&[_]u8{ch});
            self.writer.append_n_times_assume_capacity(' ', padding);
        }
        self.writer.append_slice_assume_capacity("\r\n");
    }

    /// Builds the rendered buffer and returns it. Returns either the board frame or, when the
    /// terminal is too small to fit even the minimum cell size, a centered "terminal too small"
    /// message. Caller writes the returned slice to the terminal.
    ///
    /// Infallible by design: buffer capacity is proven by RENDER_BUFFER_SIZE (16 KB) versus the
    /// worst-case frame at the largest allowed cell size (11x5) which tops out at ~12 KB. The
    /// append_*_assume_capacity calls assert in debug if that budget is ever violated, so a new
    /// escape sequence that blows past the envelope shows up as a test failure, not a mid-game
    /// process exit.
    pub fn draw(self: *BoardRenderer, game: *const Game) []const u8 {
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

        switch (self.state) {
            .ok => |dims| self.create_board_buffer(&game.board, dims),
            .too_small => |ws| self.create_too_small_buffer(ws),
        }
        std.debug.assert(self.writer.len > 0);
        return self.writer.slice();
    }

    fn create_board_buffer(self: *BoardRenderer, board: *const Board, dims: CellDimensions) void {
        std.debug.assert(dims.width >= 3);
        std.debug.assert(dims.height >= 1);

        // Board row = 3-col side margin + 8 * w-col cells + 3-col side margin.
        // Centered 5-char label: (total - 5) / 2 spaces of left padding.
        const total_width: usize = 6 + 8 * dims.width;
        // Lower bound matches MIN_COLS: smallest cell width in ALLOWED_SIZES is 3, so
        // 6 + 8*3 = 30 — the same threshold compute_cell_dimensions uses to admit a
        // CellDimensions, which is why reaching this branch guarantees the assert holds.
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
        self.writer.append_slice_assume_capacity(clear_and_home);
        self.writer.append_n_times_assume_capacity(' ', label_padding_len);
        self.writer.append_slice_assume_capacity(top_label);

        self.write_file_labels(dims);

        self.write_rank_and_pieces(board, dims);

        self.write_file_labels(dims);

        self.writer.append_slice_assume_capacity("\r\n");
        self.writer.append_n_times_assume_capacity(' ', label_padding_len);
        self.writer.append_slice_assume_capacity(bottom_label);
    }

    /// Writes a centered "terminal too small" fallback frame. Shows the minimum dimensions
    /// alongside the current window size so the user knows how much to grow the terminal.
    fn create_too_small_buffer(self: *BoardRenderer, ws: std.posix.winsize) void {
        const clear_and_home = terminal_io.EscapeSequences.CLEAR_SCREEN ++
            terminal_io.EscapeSequences.CLEAR_SCROLLBACK ++
            terminal_io.EscapeSequences.SET_CURSOR_TO_HOME;
        self.writer.append_slice_assume_capacity(clear_and_home);

        const line1 = "Terminal too small";
        var line2_storage: [64]u8 = undefined;
        // u16 formats to at most 5 digits, full string maxes at ~42 bytes, well under the 64-byte
        // backing buffer — bufPrint cannot run out of space here.
        const line2 = std.fmt.bufPrint(
            &line2_storage,
            "Need at least {d}x{d}, got {d}x{d}",
            .{ MIN_COLS, MIN_ROWS, ws.col, ws.row },
        ) catch unreachable;

        // ANSI cursor positions are 1-based. Center 3 lines of content (line1, blank, line2).
        const content_rows: u16 = 3;
        const top: u16 = if (ws.row > content_rows) (ws.row - content_rows) / 2 + 1 else 1;

        self.write_cursor_move(top, centered_col(ws.col, line1.len));
        self.writer.append_slice_assume_capacity(line1);

        self.write_cursor_move(top + 2, centered_col(ws.col, line2.len));
        self.writer.append_slice_assume_capacity(line2);
    }

    /// Column at which `content_len` bytes would sit centered within `total_cols`. Falls back to
    /// column 1 when the content is as wide or wider than the window.
    fn centered_col(total_cols: u16, content_len: usize) u16 {
        if (content_len >= total_cols) {
            return 1;
        }
        const content_u16: u16 = @intCast(content_len);
        return (total_cols - content_u16) / 2 + 1;
    }

    /// Appends an ANSI cursor-position escape (`ESC[row;colH`) to the writer. `row` and `col` are
    /// 1-based, matching the escape sequence's own convention.
    fn write_cursor_move(self: *BoardRenderer, row: u16, col: u16) void {
        var buf: [16]u8 = undefined;
        // Max output is `\x1b[65535;65535H` at 14 bytes, fits the 16-byte backing buffer.
        const seq = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, col }) catch unreachable;
        self.writer.append_slice_assume_capacity(seq);
    }

    /// Writes the rank labels and piece cells for the entire board, honoring the current
    /// perspective. Rank labels are the numbers 1 through 8 you see on the physical boards.
    ///
    /// The loop walks the board in *visual* order — (row_draw, col_draw) starts at the top-left
    /// of what the user sees and sweeps right-then-down. The mapping from visual position to
    /// board coordinates is the only thing that depends on perspective:
    ///   White: rank = 7 - row_draw, file = col_draw      (rank 8 on top, file a on left)
    ///   Black: rank = row_draw,     file = 7 - col_draw  (rank 1 on top, file h on left)
    fn write_rank_and_pieces(self: *BoardRenderer, board: *const Board, dims: CellDimensions) void {
        std.debug.assert(dims.width >= 3);
        std.debug.assert(dims.height >= 1);

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

        const mid_sub: usize = dims.height / 2;
        const padding: usize = (dims.width - 1) / 2;

        for (0..8) |row_draw| {
            const rank: usize = switch (self.perspective) {
                .white => 7 - row_draw,
                .black => row_draw,
            };

            var sub_row: usize = 0;
            while (sub_row < dims.height) : (sub_row += 1) {
                // Rank digit on the middle sub-row only, blank margin otherwise.
                const side_margin = if (sub_row == mid_sub) rank_margins[rank] else "   ";

                self.writer.append_slice_assume_capacity(side_margin);

                for (0..8) |col_draw| {
                    const file: usize = switch (self.perspective) {
                        .white => col_draw,
                        .black => 7 - col_draw,
                    };

                    const piece = board.board_state[rank][file];
                    const bg = if ((rank + file) % 2 == 0) LIGHT_BG else DARK_BG;
                    self.writer.append_slice_assume_capacity(bg);
                    if (sub_row == mid_sub) {
                        self.writer.append_n_times_assume_capacity(' ', padding);
                        self.writer.append_slice_assume_capacity(piece.fg());
                        self.writer.append_slice_assume_capacity(piece.glyph());
                        self.writer.append_n_times_assume_capacity(' ', padding);
                    } else {
                        self.writer.append_n_times_assume_capacity(' ', dims.width);
                    }
                }

                // The labeling is on both sides.
                self.writer.append_slice_assume_capacity(RESET);
                self.writer.append_slice_assume_capacity(side_margin);
                self.writer.append_slice_assume_capacity("\r\n");
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn make_winsize(cols: u16, rows: u16) std.posix.winsize {
    return .{ .col = cols, .row = rows, .xpixel = 0, .ypixel = 0 };
}

test "compute_cell_dimensions returns null when window too small" {
    try testing.expectEqual(
        @as(?BoardRenderer.CellDimensions, null),
        BoardRenderer.compute_cell_dimensions(make_winsize(10, 10)),
    );
    try testing.expectEqual(
        @as(?BoardRenderer.CellDimensions, null),
        BoardRenderer.compute_cell_dimensions(make_winsize(29, 14)),
    );
    try testing.expectEqual(
        @as(?BoardRenderer.CellDimensions, null),
        BoardRenderer.compute_cell_dimensions(make_winsize(30, 13)),
    );
}

test "compute_cell_dimensions returns non-null above threshold" {
    const dims = BoardRenderer.compute_cell_dimensions(make_winsize(30, 14));
    try testing.expect(dims != null);
    try testing.expectEqual(@as(u16, 3), dims.?.width);
    try testing.expectEqual(@as(u16, 1), dims.?.height);
}

test "compute_cell_dimensions picks largest fitting size" {
    // 6 + 8*11 = 94 cols, 6 + 8*5 = 46 rows → should pick 11x5
    const dims = BoardRenderer.compute_cell_dimensions(make_winsize(94, 46));
    try testing.expect(dims != null);
    try testing.expectEqual(@as(u16, 11), dims.?.width);
    try testing.expectEqual(@as(u16, 5), dims.?.height);
}

test "centered_col(80, 10) == 36" {
    // (80 - 10) / 2 + 1 = 36
    try testing.expectEqual(@as(u16, 36), BoardRenderer.centered_col(80, 10));
}

test "centered_col returns 1 when content wider than window" {
    try testing.expectEqual(@as(u16, 1), BoardRenderer.centered_col(5, 10));
    try testing.expectEqual(@as(u16, 1), BoardRenderer.centered_col(10, 10));
}

test "resolve_state transitions between ok and too_small at the boundary" {
    const too_small = BoardRenderer.resolve_state(make_winsize(10, 10));
    try testing.expect(too_small == .too_small);

    const ok = BoardRenderer.resolve_state(make_winsize(30, 14));
    try testing.expect(ok == .ok);
}

test "flip_perspective toggles and round-trips" {
    var renderer: BoardRenderer = undefined;
    renderer.init(make_winsize(80, 24));

    try testing.expectEqual(Color.white, renderer.perspective);
    renderer.flip_perspective();
    try testing.expectEqual(Color.black, renderer.perspective);
    renderer.flip_perspective();
    try testing.expectEqual(Color.white, renderer.perspective);
}

test "draw produces non-empty output and begins with expected ANSI prelude" {
    var renderer: BoardRenderer = undefined;
    renderer.init(make_winsize(80, 24));

    var game: Game = undefined;
    game.init(.white);

    const output = renderer.draw(&game);
    try testing.expect(output.len > 0);
    // Output should start with the clear-screen escape sequence.
    try testing.expect(std.mem.startsWith(u8, output, terminal_io.EscapeSequences.CLEAR_SCREEN));
}
