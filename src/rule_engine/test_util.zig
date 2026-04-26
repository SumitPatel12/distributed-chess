//! Classification: engine-core
//! Test-only helpers for constructing minimal rule-engine positions. Kept here so rules.zig,
//! check_helper.zig, and shared.zig tests can share the same builders without duplicating
//! setup boilerplate. Scope is deliberately tiny — two helpers. Add inline if you need more.

const Board = @import("../board.zig").Board;
const Piece = @import("../board.zig").Piece;
const shared = @import("../shared.zig");
const Position = shared.Position;

/// Returns a board with every square set to `.empty`. Tests that only care about one or two
/// pieces pair this with `place` to avoid the noise of a full starting position.
///
/// Caller contract: `king_positions` is intentionally left `undefined`. Every test that calls
/// `in_check`, `preview_move`, `piece_legal_moves`, or any other routine that reads the king
/// cache MUST first `place` both a `.white_king` and a `.black_king` on the board — `place`
/// updates the cache in sync. Skipping this is a test-author bug that will trip safety
/// assertions on first use.
pub fn empty_board() Board {
    return .{
        .squares = .{.{.empty} ** 8} ** 8,
        .king_positions = undefined,
    };
}

/// Sets `board.squares[pos.rank][pos.file] = piece`. Useful for building hand-crafted
/// positions in tests.
pub fn place(board: *Board, piece: Piece, position: Position) void {
    board.squares[position.rank][position.file] = piece;
    switch (piece) {
        .white_king => board.king_positions[@intFromEnum(shared.Color.white)] = position,
        .black_king => board.king_positions[@intFromEnum(shared.Color.black)] = position,
        else => {},
    }
}
