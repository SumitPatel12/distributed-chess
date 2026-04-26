//! Classification: engine-core
//! Zobrist hash computation over a Board state. Uses the Polyglot-canonical table
//! constants from `src/zobrist_table.zig` and the rule-engine's `en_passant_capturable`
//! predicate to honour Polyglot's "only XOR the ep file when a legal capture exists"
//! convention. Kept out of `zobrist_table.zig` so the table itself stays a pure-data leaf
//! module (no dependency on the rule engine).

const std = @import("std");
const board_mod = @import("../board.zig");
const Piece = board_mod.Piece;
const Board = board_mod.Board;
const shared = @import("../shared.zig");
const Color = shared.Color;
const Position = shared.Position;
const CastlingRights = shared.CastlingRights;
const rules = @import("rules.zig");
const zobrist_table = @import("../zobrist_table.zig");

pub const INITIAL_BOARD_ZOBRIST_HASH: u64 = blk: {
    const initial_board: Board = .{
        .squares = Board.STARTING_POSITION,
        .king_positions = .{
            .{ .rank = 0, .file = 4 }, // white king e1
            .{ .rank = 7, .file = 4 }, // black king e8
        },
    };
    break :blk hash_state(&initial_board, .white, .{}, null);
};

comptime {
    // Pins the starting-position hash at compile time. If hash_state ever grows a
    // runtime-only dependency, this assertion fails to compile instead of silently
    // pushing the XOR walk to runtime.
    std.debug.assert(INITIAL_BOARD_ZOBRIST_HASH == 0x463b96181691fc9c);
}

// I initially tried going for incremental xoring, i.e. just xoring out the pieces that moved and
// the like, it turend out to be too complex and for a game that's supposed to be played between
// humans recomputig doesn't add enough overhead to warrant that complexity. Maybe for an engine
// that would make more sense? I don't know.
pub fn hash_state(
    board: *const Board,
    turn: Color,
    castling_rights: CastlingRights,
    en_passant_square: ?Position,
) u64 {
    var hash: u64 = 0;

    for (board.squares, 0..) |rank_row, rank_idx| {
        for (rank_row, 0..) |piece, file_idx| {
            if (polyglot_kind(piece)) |kind| {
                hash ^= zobrist_table.TABLE[64 * kind + 8 * rank_idx + file_idx];
            }
        }
    }

    if (castling_rights.white_kingside) {
        hash ^= zobrist_table.TABLE[zobrist_table.CASTLING_BASE + 0];
    }
    if (castling_rights.white_queenside) {
        hash ^= zobrist_table.TABLE[zobrist_table.CASTLING_BASE + 1];
    }
    if (castling_rights.black_kingside) {
        hash ^= zobrist_table.TABLE[zobrist_table.CASTLING_BASE + 2];
    }
    if (castling_rights.black_queenside) {
        hash ^= zobrist_table.TABLE[zobrist_table.CASTLING_BASE + 3];
    }

    if (en_passant_square) |ep| {
        if (rules.en_passant_capturable(board, turn, en_passant_square)) {
            hash ^= zobrist_table.TABLE[zobrist_table.EN_PASSANT_FILE_BASE + ep.file];
        }
    }

    // Polyglot XORs side-to-move when white is to move (opposite of many engines).
    if (turn == .white) {
        hash ^= zobrist_table.SIDE_TO_MOVE;
    }

    return hash;
}

fn polyglot_kind(piece: Piece) ?usize {
    return switch (piece) {
        .empty => null,
        .white_pawn => zobrist_table.WHITE_PAWN,
        .white_knight => zobrist_table.WHITE_KNIGHT,
        .white_bishop_light, .white_bishop_dark => zobrist_table.WHITE_BISHOP,
        .white_rook => zobrist_table.WHITE_ROOK,
        .white_queen => zobrist_table.WHITE_QUEEN,
        .white_king => zobrist_table.WHITE_KING,
        .black_pawn => zobrist_table.BLACK_PAWN,
        .black_knight => zobrist_table.BLACK_KNIGHT,
        .black_bishop_light, .black_bishop_dark => zobrist_table.BLACK_BISHOP,
        .black_rook => zobrist_table.BLACK_ROOK,
        .black_queen => zobrist_table.BLACK_QUEEN,
        .black_king => zobrist_table.BLACK_KING,
    };
}

test "INITIAL_BOARD_ZOBRIST_HASH matches Polyglot reference 0x463b96181691fc9c" {
    try std.testing.expectEqual(@as(u64, 0x463b96181691fc9c), INITIAL_BOARD_ZOBRIST_HASH);
}
