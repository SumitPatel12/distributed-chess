//! Classification: engine-core
//! Test-only helpers for constructing minimal rule-engine positions. Kept here so rules.zig,
//! check_helper.zig, and shared.zig tests can share the same builders without duplicating
//! setup boilerplate. Scope is deliberately tiny — two helpers. Add inline if you need more.

const Board = @import("../board.zig").Board;
const Piece = @import("../board.zig").Piece;
const Position = @import("../shared.zig").Position;

/// Returns a board with every square set to `.empty`. Tests that only care about one or two
/// pieces pair this with `place` to avoid the noise of a full starting position.
pub fn empty_board() Board {
    return .{ .board_state = .{.{.empty} ** 8} ** 8 };
}

/// Sets `board.board_state[pos.rank][pos.file] = piece`. Useful for building hand-crafted
/// positions in tests.
pub fn place(board: *Board, piece: Piece, pos: Position) void {
    board.board_state[pos.rank][pos.file] = piece;
}
