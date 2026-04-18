//! Fixed capacity comptime array with no dynamic allocation. Tracks current size and errors out
//! when you try to write beyond the initially declared capacity.

const std = @import("std");

/// A fixed-capacity array that tracks how many elements have been written.
/// No allocator needed — the buffer lives inline at comptime-known size.
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        /// Number of elements currently held in `buf`.
        /// Also the position where the next append will start.
        len: usize = 0,

        const Self = @This();
        const Error = error{Overflow};

        /// Resets the length so the array can be reused.
        pub fn reset(self: *Self) void {
            std.debug.assert(self.len <= capacity);
            self.len = 0;
        }

        /// Appends a slice of elements to the end of the array.
        pub fn append_slice(self: *Self, items: []const T) Error!void {
            std.debug.assert(self.len <= capacity);

            if (self.len + items.len > capacity) {
                return error.Overflow;
            }

            @memcpy(self.buf[self.len .. self.len + items.len], items);
            self.len += items.len;
        }

        /// Appends `n` copies of `value` to the end of the array.
        pub fn append_n_times(self: *Self, value: T, n: usize) Error!void {
            std.debug.assert(self.len <= capacity);

            if (self.len + n > capacity) {
                return error.Overflow;
            }

            @memset(self.buf[self.len .. self.len + n], value);
            self.len += n;
        }

        /// Appends a slice of elements. Caller has already proven capacity (e.g. via a budget
        /// check at the top of a render), so an overflow here is a programmer bug and we assert
        /// rather than returning an error.
        pub fn append_slice_assume_capacity(self: *Self, items: []const T) void {
            std.debug.assert(self.len + items.len <= capacity);
            @memcpy(self.buf[self.len .. self.len + items.len], items);
            self.len += items.len;
        }

        /// Appends a single element. Capacity is a caller-proven precondition — same contract as
        /// `append_slice_assume_capacity`, optimized for the common case where the caller knows
        /// there's room for exactly one more.
        pub fn append_assume_capacity(self: *Self, item: T) void {
            std.debug.assert(self.len + 1 <= capacity);
            self.buf[self.len] = item;
            self.len += 1;
        }

        /// Appends `n` copies of `value`. Capacity is a caller-proven precondition.
        pub fn append_n_times_assume_capacity(self: *Self, value: T, n: usize) void {
            std.debug.assert(self.len + n <= capacity);
            @memset(self.buf[self.len .. self.len + n], value);
            self.len += n;
        }

        /// Returns the populated portion of the array.
        pub fn slice(self: *const Self) []const T {
            std.debug.assert(self.len <= capacity);
            return self.buf[0..self.len];
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "append_slice returns overflow when appending items would exceed capacity" {
    var array: BoundedArray(u8, 4) = .{};
    try std.testing.expectError(error.Overflow, array.append_slice(&.{ 1, 2, 3, 4, 5 }));
}

test "append_slice returns void when appending items that fit into the capacity" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_slice(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, array.slice());
}

test "append_slice chained calls update the buffer correctly" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_slice(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, array.slice());

    try array.append_slice(&.{ 3, 4 });
    try std.testing.expectEqual(@as(usize, 4), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, array.slice());

    try array.append_slice(&.{5});
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, array.slice());
}

test "append_slice chained calls update the buffer correctly until capacity overflow is reached" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_slice(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, array.slice());

    try array.append_slice(&.{ 3, 4 });
    try std.testing.expectEqual(@as(usize, 4), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, array.slice());

    try array.append_slice(&.{5});
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, array.slice());

    try std.testing.expectError(error.Overflow, array.append_slice(&.{ 6, 7 }));

    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, array.slice());
}

test "append_n_times returns overflow when appending items would exceed capacity" {
    var array: BoundedArray(u8, 4) = .{};
    try std.testing.expectError(error.Overflow, array.append_n_times(4, 5));
}

test "append_n_times returns void when appending items that fit into the capacity" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_n_times(5, 5);
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 5, 5, 5 }, array.slice());
}

test "append_n_time chained calls update buffer correctly" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_n_times(5, 2);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5 }, array.slice());

    try array.append_n_times(2, 2);
    try std.testing.expectEqual(@as(usize, 4), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 2, 2 }, array.slice());

    try array.append_n_times(3, 1);
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 2, 2, 3 }, array.slice());
}

test "append_n_time chained calls update buffer correctly and keeps the buffer state if overflow occurs" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_n_times(5, 2);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5 }, array.slice());

    try array.append_n_times(2, 2);
    try std.testing.expectEqual(@as(usize, 4), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 2, 2 }, array.slice());

    try array.append_n_times(3, 1);
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 2, 2, 3 }, array.slice());

    try std.testing.expectError(error.Overflow, array.append_n_times(4, 3));

    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 2, 2, 3 }, array.slice());
}

test "reset restes the len back to 0 after append_n_times" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_n_times(5, 5);
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 5, 5, 5 }, array.slice());
    array.reset();
    try std.testing.expectEqual(@as(usize, 0), array.len);
}

test "reset resets the len back to 0 after append_slice" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_slice(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, array.slice());
    array.reset();
    try std.testing.expectEqual(@as(usize, 0), array.len);
}

test "append_assume_capacity writes item at buf[len-1] across sequential calls" {
    var array: BoundedArray(u8, 6) = .{};
    array.append_assume_capacity(10);
    try std.testing.expectEqual(@as(usize, 1), array.len);
    try std.testing.expectEqual(@as(u8, 10), array.buf[0]);

    array.append_assume_capacity(20);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqual(@as(u8, 20), array.buf[1]);

    array.append_assume_capacity(30);
    try std.testing.expectEqual(@as(usize, 3), array.len);
    try std.testing.expectEqual(@as(u8, 30), array.buf[2]);

    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, array.slice());
}

test "append_assume_capacity fills to capacity without panic" {
    var array: BoundedArray(u8, 4) = .{};
    array.append_assume_capacity(1);
    array.append_assume_capacity(2);
    array.append_assume_capacity(3);
    array.append_assume_capacity(4);
    try std.testing.expectEqual(@as(usize, 4), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, array.slice());
}

test "reset keeps the buffer for reuse" {
    var array: BoundedArray(u8, 6) = .{};
    try array.append_slice(&.{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(usize, 5), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, array.slice());
    array.reset();
    try std.testing.expectEqual(@as(usize, 0), array.len);

    try array.append_n_times(5, 2);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5 }, array.slice());

    try array.append_slice(&.{ 2, 4 });
    try std.testing.expectEqual(@as(usize, 4), array.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 5, 2, 4 }, array.slice());

    array.reset();
    try std.testing.expectEqual(@as(usize, 0), array.len);
}
