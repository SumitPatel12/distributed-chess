// The standard library likely has a better implementation than what I haev here, a serious
// implementation would either use that or some form of SIMD I guess.
const std = @import("std");

/// A fixed-lenght BitSet. Used to represent quorum responses, each bit represents whether or not a
/// node has replied to the request or not.
pub fn BitSet(comptime T: type, comptime size: usize) type {
    comptime {
        if (T != @TypeOf(u32) and T != @TypeOf(u64)) {
            @compileError("T must be u32 or u64");
        }
    }

    const word_bits = @bitSizeOf(T);
    const words_len = std.math.divCeil(usize, size, word_bits) catch unreachable;

    return struct {
        words: [words_len]T = [_]T{0} ** words_len,

        const Self = @This();

        /// Sets the val indexed bit to 1.
        pub fn set(self: *Self, value: usize) void {
            std.debug.assert(value < size);

            const index = value / self.word_size;
            // This makes sure that the offset we get fits in the number of bits that T has.
            const offset: std.math.Log2Int(T) = @intCast(value % self.word_size);

            self.words[index] |= (1 << offset);
        }

        /// Unsets the val indexed bit. So, set's it to 0.
        pub fn unset(self: *Self, value: usize) void {
            std.debug.assert(value < size);

            const index = value / self.word_size;
            // This makes sure that the offset we get fits in the number of bits that T has.
            const offset: std.math.Log2Int(T) = @intCast(value % self.word_size);

            self.words[index] &= ~(1 << offset);
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
