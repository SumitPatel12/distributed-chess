//! Tracks piece placement on the board and exposes state queries used by the rule engine
//! (king position lookup, piece position lookup). Does NOT apply rule logic — move legality,
//! check detection, ray walking, and turn enforcement live in `rule_engine/`.

const std = @import("std");
const terminal_io = @import("terminal_io.zig");
const shared = @import("shared.zig");
const Color = shared.Color;
const Position = shared.Position;
const BoundedArray = @import("bounded_array.zig").BoundedArray;

const WHITE_PIECE_FG = terminal_io.EscapeSequences.fg_rgb(255, 255, 255);
const BLACK_PIECE_FG = terminal_io.EscapeSequences.fg_rgb(0, 0, 0);

// White: ♔ U+2654   ♕ U+2655   ♖ U+2656   ♗ U+2657   ♘ U+2658   ♙ U+2659
// Black: ♚ U+265A   ♛ U+265B   ♜ U+265C   ♝ U+265D   ♞ U+265E   ♟ U+265F
//
// i8 because the board state needs to capture two things:
//  1. Piece Position
//  2. Piece Color
// Positive would be white and negative would be black. And since we only have 6 unique pieces i8 is
// more than enough.
/// Enum for pieces, the board_state will make use of this to encode the board state.
pub const Piece = enum(i8) {
    empty = 0,
    white_pawn = 1,
    white_knight = 2,
    white_bishop_light = 3,
    white_bishop_dark = 4,
    white_rook = 5,
    white_queen = 6,
    white_king = 7,
    black_pawn = -1,
    black_knight = -2,
    black_bishop_light = -3,
    black_bishop_dark = -4,
    black_rook = -5,
    black_queen = -6,
    black_king = -7,

    pub fn color(self: Piece) ?Color {
        const int_value = @intFromEnum(self);
        std.debug.assert(int_value >= -7 and int_value <= 7);

        if (int_value == 0) {
            return null;
        } else if (int_value > 0) {
            return .white;
        } else {
            return .black;
        }
    }

    /// Returns the UTF-8 glyph for this piece. Both colors use the filled
    /// (solid) glyph set — the U+265A..F range — and colors are distinguished
    /// by foreground SGR instead of outline-vs-filled. Empty renders as a
    /// space so it can be dropped into the render buffer directly.
    pub fn glyph(self: Piece) []const u8 {
        return switch (self) {
            .empty => " ",
            .white_pawn, .black_pawn => "\u{265F}",
            .white_knight, .black_knight => "\u{265E}",
            .white_bishop_light,
            .white_bishop_dark,
            .black_bishop_light,
            .black_bishop_dark,
            => "\u{265D}",
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
            .white_pawn,
            .white_knight,
            .white_bishop_light,
            .white_bishop_dark,
            .white_rook,
            .white_queen,
            .white_king,
            => WHITE_PIECE_FG,
            .black_pawn,
            .black_knight,
            .black_bishop_light,
            .black_bishop_dark,
            .black_rook,
            .black_queen,
            .black_king,
            => BLACK_PIECE_FG,
        };
    }
};

/// Encodes the current board.
/// Keeps track of the board state with piece positions.
pub const Board = struct {
    /// Current State of the board with piece positions.
    /// Row 0 is black's back rank and row 7 is white's back rank.
    board_state: [8][8]Piece,

    /// Cached king positions — maintained in lockstep with `board_state` so `find_king_position`
    /// is O(1). Indexed as `king_pos[@intFromEnum(color)]` (white = 0, black = 1).
    ///
    /// Coherence contract: `Board.move` updates this cache automatically, and `Board.clear`
    /// asserts its target is not a king. Any code path that writes directly into `board_state`
    /// (test fixtures bypassing `move`, low-level state patching) MUST maintain `king_pos` by
    /// hand — see `src/rule_engine/test_util.zig` (`place`) and `src/game.zig`'s pin-scenario
    /// test for examples. A stale cache trips the `expected_king` assert in
    /// `check_helper.in_check`.
    king_pos: [2]Position,

    // Chess board anatomy:
    //
    // Files run a..h left to right, ranks run 1..8 from white's side up to black's. A square is
    // named <file><rank> — e.g. the white king starts on e1, the black king on e8, and the move
    // "e4" points at the square shown in the middle of the diagram below. The bottom right corner
    // of the board is always a light square, irrespective of which players perspective you see from
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
    // board_state is indexed as board_state[rank_idx][file_idx], with rank_idx 0 mapping to chess
    // rank 1 (white's back rank) and rank_idx 7 to chess rank 8 (black's back rank). The array
    // layout is flipped vertically relative to the anatomy diagram above, so "e4" translates
    // directly to board_state[3][4] — no mental flip, rank_idx and chess rank line up exactly.
    //
    // I initially had this encoded as we see in the anatomy diagram above: for the 2D array, white
    // sat at the bottom (high rank_idx) and black at the top (low rank_idx). That inverted every
    // rank lookup — a pawn push from e2 -> e4 read as board_state[6][4] -> board_state[4][4]
    // instead of the natural board_state[1][4] -> board_state[3][4]. I'd be paying that translation
    // cost at every call site for white's position, and moves are what the whole game is built on,
    // so I flipped the convention once here rather than forever at every access.
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
    // Note how in BEFORE the array "looks right" (black on top, white on bottom like you'd set up a
    // real board) but rank_idx 0 = rank 8 and rank_idx 7 = rank 1 — every piece of move logic has
    // to do `8 - rank` to index white. In NOW the array is upside down compared to the physical
    // board, but rank_idx == (chess rank - 1), so the translation vanishes.
    //
    /// The starting position for a classical game. Sorted by rank and file so white side first.
    const STARTING_BOARD_POSITION: [8][8]Piece = .{
        .{
            .white_rook, .white_knight,       .white_bishop_dark, .white_queen,
            .white_king, .white_bishop_light, .white_knight,      .white_rook,
        },
        .{.white_pawn} ** 8,
        .{.empty} ** 8,
        .{.empty} ** 8,
        .{.empty} ** 8,
        .{.empty} ** 8,
        .{.black_pawn} ** 8,
        .{
            .black_rook, .black_knight,      .black_bishop_light, .black_queen,
            .black_king, .black_bishop_dark, .black_knight,       .black_rook,
        },
    };

    // NOTE: Since this is initialized in-place make sure that all of the things that it calls
    // during the init also support in-place initialization.
    /// Initialize the board with the starting position.
    /// Initialization takes place in-place
    pub fn init(self: *Board) void {
        self.* = .{
            .board_state = STARTING_BOARD_POSITION,
            .king_pos = .{
                Position{ .rank = 0, .file = 4 }, // white king e1
                Position{ .rank = 7, .file = 4 }, // black king e8
            },
        };
    }

    // Move doesn't consider any rule logic because I've decided to leave that up to the game
    // struct. I wanted to keep the board as just a dumb array that would make the moves its told.
    // Additionally move history captures, etc would live on the game struct and not the board, and
    // then move would have to return captured pieces, encode en-passant, castling and that gets
    // difficult fast. At least that's what I imagine, hence the dumb state board.
    //
    /// Mutates `board_state` to move a piece from `from` to `to`. Doesn't re-draw, if you want the
    /// new state to be visible call the redraw function.
    pub fn move(self: *Board, from: Position, to: Position) void {
        // A move that doesn't change the square is not a move.
        std.debug.assert(from.rank != to.rank or from.file != to.file);

        const piece = self.board_state[from.rank][from.file];
        // Can't move a piece that isn't there.
        std.debug.assert(piece != .empty);

        self.board_state[from.rank][from.file] = .empty;
        self.board_state[to.rank][to.file] = piece;

        switch (piece) {
            .white_king => self.king_pos[@intFromEnum(Color.white)] = to,
            .black_king => self.king_pos[@intFromEnum(Color.black)] = to,
            else => {},
        }
    }

    /// Set's the given position to empty. Will be required for en-passant.
    pub fn clear(self: *Board, position: Position) void {
        const piece = self.board_state[position.rank][position.file];
        std.debug.assert(piece != .white_king and piece != .black_king);
        self.board_state[position.rank][position.file] = .empty;
    }

    // Kings position is so commonly required to check if it's under check that it warranted its own
    // method.
    /// Returns the position of the king of the given color.
    /// According to the rules of chess there's always a king on the board for both sides, so this
    /// function is always guaranteed to return as valid position.
    pub fn find_king_position(self: *const Board, color: Color) Position {
        return self.king_pos[@intFromEnum(color)];
    }

    // Capacity 10 covers the worst case for any piece type: 2 starting rooks/knights plus up to 8
    // promotions. Queens, bishops (per square colour), and pawns all cap below this.
    //
    /// Returns every board square occupied by `piece`, in rank-major order. Result Location
    /// Semantics guarantees the returned aggregate is written directly to the caller's destination.
    pub fn find_piece_position(self: *const Board, piece: Piece) BoundedArray(Position, 10) {
        std.debug.assert(piece != .empty);

        var result: BoundedArray(Position, 10) = .{};
        for (self.board_state, 0..) |rank, rank_idx| {
            for (rank, 0..) |board_piece, file_idx| {
                if (board_piece == piece) {
                    result.append_assume_capacity(.{
                        .rank = @intCast(rank_idx),
                        .file = @intCast(file_idx),
                    });
                }
            }
        }
        return result;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "move applies piece from source to destination and clears source" {
    var board: Board = undefined;
    board.init();

    // Move white pawn e2 -> e4 (rank 1 file 4 -> rank 3 file 4)
    const from = Position{ .rank = 1, .file = 4 };
    const to = Position{ .rank = 3, .file = 4 };

    try testing.expectEqual(Piece.white_pawn, board.board_state[from.rank][from.file]);
    try testing.expectEqual(Piece.empty, board.board_state[to.rank][to.file]);

    board.move(from, to);

    try testing.expectEqual(Piece.empty, board.board_state[from.rank][from.file]);
    try testing.expectEqual(Piece.white_pawn, board.board_state[to.rank][to.file]);
}

test "clear zeroes target square and leaves adjacent squares untouched" {
    var board: Board = undefined;
    board.init();

    const target = Position{ .rank = 0, .file = 3 }; // white queen at d1

    // Snapshot neighbours before clearing.
    const left = board.board_state[0][2]; // c1 bishop
    const right = board.board_state[0][4]; // e1 king

    board.clear(target);

    try testing.expectEqual(Piece.empty, board.board_state[target.rank][target.file]);
    try testing.expectEqual(left, board.board_state[0][2]);
    try testing.expectEqual(right, board.board_state[0][4]);
}

test "move preserves board integrity under a scripted sequence" {
    var board: Board = undefined;
    board.init();

    // Count non-empty pieces at the start — should be 32.
    const initial_count = countPieces(&board);
    try testing.expectEqual(@as(usize, 32), initial_count);

    // Play a short scripted sequence (no captures).
    const moves = [_][2]Position{
        .{ .{ .rank = 1, .file = 4 }, .{ .rank = 3, .file = 4 } }, // e2-e4
        .{ .{ .rank = 6, .file = 4 }, .{ .rank = 4, .file = 4 } }, // e7-e5
        .{ .{ .rank = 0, .file = 6 }, .{ .rank = 2, .file = 5 } }, // Ng1-f3
        .{ .{ .rank = 7, .file = 1 }, .{ .rank = 5, .file = 2 } }, // Nb8-c6
    };

    for (moves) |move| {
        board.move(move[0], move[1]);
    }

    // No captures — piece count must still be 32.
    try testing.expectEqual(@as(usize, 32), countPieces(&board));
}

test "Piece.glyph returns distinct non-empty UTF-8 for each piece variant" {
    const fields = @typeInfo(Piece).@"enum".fields;
    // 15 variants: empty + 7 white + 7 black (bishops split into light/dark squared)
    try testing.expectEqual(@as(usize, 15), fields.len);

    inline for (fields) |field| {
        const piece: Piece = @enumFromInt(field.value);
        const glyph = piece.glyph();
        try testing.expect(glyph.len > 0);
    }

    // Glyphs for same role but different colour should be identical (both use filled set).
    try testing.expectEqualStrings(Piece.white_king.glyph(), Piece.black_king.glyph());
    try testing.expectEqualStrings(Piece.white_queen.glyph(), Piece.black_queen.glyph());
}

test "Piece.fg differs for white vs black same-role pieces" {
    // White and black pieces must receive different foreground SGR sequences.
    try testing.expect(!std.mem.eql(u8, Piece.white_pawn.fg(), Piece.black_pawn.fg()));
    try testing.expect(!std.mem.eql(u8, Piece.white_king.fg(), Piece.black_king.fg()));

    // Empty piece should have an empty fg string.
    try testing.expectEqual(@as(usize, 0), Piece.empty.fg().len);
}

test "find_king_position returns e1 for white on the starting board" {
    var board: Board = undefined;
    board.init();

    const pos = board.find_king_position(.white);
    try testing.expectEqual(@as(u3, 0), pos.rank);
    try testing.expectEqual(@as(u3, 4), pos.file);
}

test "find_king_position returns e8 for black on the starting board" {
    var board: Board = undefined;
    board.init();

    const pos = board.find_king_position(.black);
    try testing.expectEqual(@as(u3, 7), pos.rank);
    try testing.expectEqual(@as(u3, 4), pos.file);
}

test "find_king_position finds king after it moves e1 -> e2" {
    var board: Board = undefined;
    board.init();

    // Clear e2 (white pawn there on init) so the move target is empty, then walk the king up.
    board.clear(.{ .rank = 1, .file = 4 });
    board.move(.{ .rank = 0, .file = 4 }, .{ .rank = 1, .file = 4 });

    const pos = board.find_king_position(.white);
    try testing.expectEqual(@as(u3, 1), pos.rank);
    try testing.expectEqual(@as(u3, 4), pos.file);
}

test "find_piece_position returns 8 white pawns on rank 1 for starting board" {
    var board: Board = undefined;
    board.init();

    const positions = board.find_piece_position(.white_pawn);
    try testing.expectEqual(@as(usize, 8), positions.len);
    for (positions.slice()) |position| {
        try testing.expectEqual(@as(u3, 1), position.rank);
    }
}

fn countPieces(board: *const Board) usize {
    var count: usize = 0;
    for (board.board_state) |rank| {
        for (rank) |square| {
            if (square != .empty) {
                count += 1;
            }
        }
    }
    return count;
}
