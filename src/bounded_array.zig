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
            self.len = 0;
        }

        /// Appends a slice of elements to the end of the array.
        pub fn append_slice(self: *Self, items: []const T) Error!void {
            if (self.len + items.len > capacity) return error.Overflow;
            @memcpy(self.buf[self.len .. self.len + items.len], items);
            self.len += items.len;
        }

        /// Appends `n` copies of `value` to the end of the array.
        pub fn append_n_times(self: *Self, value: T, n: usize) Error!void {
            if (self.len + n > capacity) return error.Overflow;
            @memset(self.buf[self.len .. self.len + n], value);
            self.len += n;
        }

        /// Returns the populated portion of the array.
        pub fn slice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }
    };
}
