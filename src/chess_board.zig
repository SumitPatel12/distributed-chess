const std = @import("std");
const terminal_io = @import("terminal_io.zig");

const WHITE_PIECE_FG = terminal_io.EscapeSequences.fg_rgb(255, 255, 255, "");
const BLACK_PIECE_FG = terminal_io.EscapeSequences.fg_rgb(0, 0, 0, "");

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

pub const Board = struct {
    /// Current State of the board with piece positions.
    /// Row 0 is black's back rank and row 7 is white's back rank.
    board_state: [8][8]Piece,

    // This can likely be merged with board_state since it does have extra bits, that's an optimization I'll handle down the line.
    // 8x8 bits no need to waste so much space for this, each bit will represent whether that square is valid for that piece or not, at least that's what I'm aiming for.
    /// Will encode move hints when a piece is selected.
    board_overlay: [8][8]u1,

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

    const EMPTY_OVERLAY: [8][8]u1 = .{.{0} ** 8} ** 8;

    pub fn init_board() Board {
        return Board{ .board_state = STARTING_BOARD_POSITION, .board_overlay = EMPTY_OVERLAY };
    }

    pub fn draw_board(window_config: std.posix.winsize) !void {
        _ = window_config;

        const light_bg = comptime terminal_io.EscapeSequences.bg_rgb(184, 201, 134, "");
        const dark_bg = comptime terminal_io.EscapeSequences.bg_rgb(106, 138, 61, "");
        const reset = terminal_io.EscapeSequences.RESET_STYLE_AND_COLOR;

        // Board row = 3-col side margin + 8 * 7-col cells = 59 cols wide.
        // Centered 5-char label: (59 - 5) / 2 = 27 spaces of left padding.
        const label_pad = " " ** 27;
        const black_label = label_pad ++ "BLACK" ++ "\r\n";
        const white_label = label_pad ++ "WHITE" ++ "\r\n";

        // File letters (a..h), one per 7-col cell, with a 3-col left margin
        // to match the rank digit column.
        const alphabetic_label = "      a      b      c      d      e      f      g      h   \r\n";

        // Left-edge rank labels. Index 0 is the black back rank (chess rank 8).
        const rank_margins = [_][]const u8{ " 8 ", " 7 ", " 6 ", " 5 ", " 4 ", " 3 ", " 2 ", " 1 " };

        // Initial position is always the same so we're going the comptime route.
        const buffer = comptime blk: {
            var buf: []const u8 = black_label ++ "\n\r" ++ alphabetic_label;

            for (STARTING_BOARD_POSITION, 0..) |rank_row, rank| {
                var sub_row: usize = 0;
                while (sub_row < 3) : (sub_row += 1) {
                    // Rank digit on the middle sub-row only, blank margin otherwise.
                    const side_margin = if (sub_row == 1) rank_margins[rank] else "   ";

                    var row: []const u8 = side_margin;
                    for (rank_row, 0..) |piece, file| {
                        const bg = if ((rank + file) % 2 == 0) light_bg else dark_bg;
                        // Middle row holds the glyph with some padding to center it
                        const content = if (sub_row == 1)
                            "   " ++ piece.fg() ++ piece.glyph() ++ "   "
                        else
                            "       ";
                        row = row ++ bg ++ content;
                    }

                    // The labeling is on both sides.
                    buf = buf ++ row ++ reset ++ side_margin ++ "\r\n";
                }
            }

            buf = buf ++ alphabetic_label ++ "\r\n" ++ white_label;
            break :blk buf;
        };

        const result_code = terminal_io.TerminalIO.write(buffer);
        if (result_code == -1) {
            std.debug.print("Failed to render to the terminal.", .{});
        }
    }
};
