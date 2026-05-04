// The standard library likely has a better implementation than what I haev here, a serious
// implementation would either use that or some form of SIMD I guess.
const std = @import("std");

/// A fixed-lenght BitSet. Used to represent quorum responses, each bit represents whether or not a
/// node has replied to the request or not.
///
/// Supports u32 and u64 only. Comptime errors if any other type is provided.
pub fn BitSet(comptime T: type, comptime size: usize) type {
    return struct {
        comptime {
            if (T != u32 and T != u64) {
                @compileError("T must be u32 or u64");
            }
        }

        pub const word_size = @bitSizeOf(T);
        pub const words_len = std.math.divCeil(usize, size, word_size) catch unreachable;

        words: [words_len]T = [_]T{0} ** words_len,

        const Self = @This();

        /// Sets the val indexed bit to 1.
        pub fn set(self: *Self, value: usize) void {
            std.debug.assert(value < size);

            const index = value / word_size;
            // This makes sure that the offset we get fits in the number of bits that T has.
            const offset: std.math.Log2Int(T) = @intCast(value % word_size);

            self.words[index] |= (@as(T, 1) << offset);
        }

        /// Unsets the val indexed bit. So, set's it to 0.
        pub fn unset(self: *Self, value: usize) void {
            std.debug.assert(value < size);

            const index = value / word_size;
            // This makes sure that the offset we get fits in the number of bits that T has.
            const offset: std.math.Log2Int(T) = @intCast(value % word_size);

            self.words[index] &= ~(@as(T, 1) << offset);
        }

        /// Returns the total set bits in the current bitset.
        pub fn count(self: *const Self) usize {
            var total: usize = 0;

            for (self.words) |word| {
                total += @popCount(word);
            }

            return total;
        }
    };
}

// --- Tests ---------------------------------------------------------------------------------------
test "check init, word_size, and words_len" {
    const NodeBitSet = BitSet(u64, 1);
    try std.testing.expectEqual(@as(usize, 64), NodeBitSet.word_size);
    try std.testing.expectEqual(@as(usize, 1), NodeBitSet.words_len);

    var bs: NodeBitSet = .{};
    bs.set(0);
    try std.testing.expectEqual(@as(usize, 1), bs.count());

    bs.unset(0);
    try std.testing.expectEqual(@as(usize, 0), bs.count());
}
