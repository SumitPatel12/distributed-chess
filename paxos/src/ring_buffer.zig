const std = @import("std");

// TODO: Maybe we should have a deinit here?
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime {
        std.debug.assert(capacity > 0);
    }

    return struct {
        buffer: [capacity]T = undefined,
        count: usize = 0,
        head: usize = 0,

        const Self = @This();
        const Error = error{Overflow};

        pub inline fn reset(self: *Self) void {
            self.count = 0;
            self.head = 0;
        }

        pub inline fn push(self: *Self, value: T) Error!void {
            if (self.full()) {
                return error.Overflow;
            }

            self.buffer[(self.head + self.count) % capacity] = value;
            self.count += 1;
        }

        pub inline fn peek(self: *const Self) ?T {
            if (self.empty()) {
                return null;
            }

            return self.buffer[self.head];
        }

        pub inline fn pop(self: *Self) ?T {
            if (self.empty()) {
                return null;
            }

            const value = self.buffer[self.head];
            self.count -= 1;
            self.head = (self.head + 1) % capacity;
            return value;
        }

        pub inline fn empty(self: *const Self) bool {
            return self.count == 0;
        }

        pub inline fn full(self: *const Self) bool {
            return self.count == capacity;
        }
    };
}

const RB4 = RingBuffer(u32, 4);

test "RingBuffer: empty/full, FIFO order" {
    var rb: RB4 = .{};
    try std.testing.expect(rb.empty());
    try std.testing.expect(!rb.full());
    try rb.push(10);
    try rb.push(20);
    try rb.push(30);
    try rb.push(40);
    try std.testing.expect(rb.full());
    try std.testing.expectError(error.Overflow, rb.push(50));
    try std.testing.expectEqual(@as(?u32, 10), rb.pop());
    try std.testing.expectEqual(@as(?u32, 20), rb.peek());
    try std.testing.expectEqual(@as(?u32, 20), rb.pop());
    try rb.push(50);
    try std.testing.expectEqual(@as(?u32, 30), rb.pop());
    try std.testing.expectEqual(@as(?u32, 40), rb.pop());
    try std.testing.expectEqual(@as(?u32, 50), rb.pop());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
    try std.testing.expect(rb.empty());
}

test "RingBuffer: indices wrap (push past capacity over time)" {
    var rb: RB4 = .{};
    var n: u32 = 0;
    while (n < 100) : (n += 1) {
        try rb.push(n);
        try std.testing.expectEqual(@as(?u32, n), rb.pop());
        try std.testing.expect(rb.empty());
    }
}
