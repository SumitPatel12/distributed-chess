const std = @import("std");
const terminal_io = @import("terminal_io.zig");

// White: ♔ U+2654   ♕ U+2655   ♖ U+2656   ♗ U+2657   ♘ U+2658   ♙ U+2659
// Black: ♚ U+265A   ♛ U+265B   ♜ U+265C   ♝ U+265D   ♞ U+265E   ♟ U+265F
/// Enum for pieces, the board_state will make use of this to encode the board state.
const Piece = enum(i8) {
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
};

pub const Board = struct {
    // i8 because the board state needs to capture two things:
    //  1. Piece Position
    //  2. Piece Color
    // Positive would be white and negative would be black. And since we only have 6 unique pieces i8 is more than enough.

    /// Current State of the board with piece positions.
    /// Row 0 is white side and row 8 is black side.
    board_state: i8[8][8],

    // This can likely be merged with board_state since it does have extra bits, that's an optimization I'll handle down the line.
    // 8x8 bits no need to waste so much space for this, each bit will represent whether that square is valid for that piece or not, at least that's what I'm aiming for.
    /// Will encode move hints when a piece is selected.
    board_overlay: u8[8][1],

    /// The starting position for a classical game
    const STARTING_BOARD_POSITION: [8][8]i8 = .{
        .{ Piece.BlackRook, Piece.BlackKnight, Piece.BlackBhishop, Piece.BlackQueen, Piece.BlackBhishop, Piece.BlackKnight, Piece.BlackRook },
        .{ Piece.BlackPawn, Piece.BlackPawn, Piece.BlackPawn, Piece.BlackPawn, Piece.BlackPawn, Piece.BlackPawn, Piece.BlackPawn, Piece.BlackPawn },
        .{.{Piece.Empty} ** 8},
        .{.{Piece.Empty} ** 8},
        .{.{Piece.Empty} ** 8},
        .{.{Piece.Empty} ** 8},
        .{ Piece.WhitePawn, Piece.WhitePawn, Piece.WhitePawn, Piece.WhitePawn, Piece.WhitePawn, Piece.WhitePawn, Piece.WhitePawn, Piece.WhitePawn },
        .{ Piece.WhiteRook, Piece.WhiteKnight, Piece.WhiteBhishop, Piece.WhiteQueen, Piece.WhiteBhishop, Piece.WhiteKnight, Piece.WhiteRook },
    };

    const EMTPY_OVERLAY: [8][1]u8 = .{
        .{0},
        .{0},
        .{0},
        .{0},
        .{0},
        .{0},
        .{0},
    };

    pub fn init_board() Board {
        return Board{ .board_state = STARTING_BOARD_POSITION, .board_overlay = .{} };
    }

    pub fn draw_board(window_config: std.posix.winsize) !void {
        _ = window_config;

        const light = comptime terminal_io.EscapeSequences.bg_rgb(240, 217, 181);
        const dark = comptime terminal_io.EscapeSequences.bg_rgb(181, 136, 99);
        const reset = terminal_io.EscapeSequences.RESET_STYLE_AND_COLOR;

        const buffer = comptime blk: {
            var buf: []const u8 = "";
            var rank: usize = 0;
            while (rank < 8) : (rank += 1) {
                var file: usize = 0;
                var row: []const u8 = "";
                while (file < 8) : (file += 1) {
                    row = row ++ (if ((rank + file) % 2 == 0) light else dark) ** 3;
                }

                row = row ++ reset ++ "\r\n";
                buf = buf ++ (row ** 3);
            }
            break :blk buf;
        };

        const result_code = std.c.write(std.posix.STDOUT_FILENO, buffer.ptr, buffer.len);
        if (result_code == -1) {
            std.debug.print("Failed to render to the terminal.", .{});
        }
    }
};
