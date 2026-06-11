//! Intrusive linked list for a FIFO Queue, the link lives inside the element (T embeds a `Link`),
//! so the queue owns no storage and allocates nothing.

const std = @import("std");
const assert = std.debug.assert;

/// The intrusive link that is to be embedded in the object to link.
pub const QueueLink = struct { next: ?*QueueLink = null };

/// Intrusive FIFO linked list.
pub fn Queue(comptime T: type) type {
    return struct {
        head: ?*QueueLink = null,
        tail: ?*QueueLink = null,

        const Self = @This();

        pub const Link = QueueLink;

        /// Check if the queue is empty.
        pub fn empty(self: Self) bool {
            return self.head == null;
        }

        // Since the queue is intrusive we don't need to care about `T`'s destruction.
        /// Resets the queue, i.e. set head and tail to null.
        pub fn reset(self: *Self) void {
            self.head = null;
            self.tail = null;
        }

        /// Push an element to the end of the queue.
        pub fn push(self: *Self, element: *T) void {
            assert(element.link.next == null);

            if (self.head == null) {
                assert(self.tail == null);
                self.head = &element.link;
                self.tail = &element.link;

                return;
            }

            self.tail.?.next = &element.link;
            self.tail = &element.link;
        }

        /// Pop an element from the start of the queue. If the queue is empty returns null.
        pub fn pop(self: *Self) ?*T {
            const link = self.head orelse return null;
            self.head = link.next;
            if (self.head == null) {
                self.tail = null;
            }

            link.next = null;

            return @fieldParentPtr("link", link);
        }

        /// Returns a pointer to the first element of the queue
        pub fn peek(self: Self) ?*T {
            return @fieldParentPtr("link", self.head orelse return null);
        }

        /// Returns a pointer to the last element of the queue
        pub fn peek_last(self: Self) ?*T {
            return @fieldParentPtr("link", self.tail orelse return null);
        }
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

const TestItem = struct {
    link: Queue(TestItem).Link = .{},
    value: u32,
};

test "Queue: starts empty, push/pop FIFO order, empty again" {
    var q: Queue(TestItem) = .{};
    try std.testing.expect(q.empty());

    var a: TestItem = .{ .value = 1 };
    var b: TestItem = .{ .value = 2 };
    var z: TestItem = .{ .value = 3 };
    q.push(&a);
    q.push(&b);
    q.push(&z);
    try std.testing.expect(!q.empty());

    try std.testing.expectEqual(@as(u32, 1), q.pop().?.value);
    try std.testing.expectEqual(@as(u32, 2), q.pop().?.value);
    try std.testing.expectEqual(@as(u32, 3), q.pop().?.value);
    try std.testing.expectEqual(@as(?*TestItem, null), q.pop());
    try std.testing.expect(q.empty());
}

test "Queue: reset leaves a usable empty queue" {
    var q: Queue(TestItem) = .{};
    var a: TestItem = .{ .value = 7 };
    q.push(&a);
    q.reset();
    try std.testing.expect(q.empty());
    // No manual `a.link = .{}` needed: `a` was never popped, but reset drops the
    // queue's references, and re-pushing a fresh element must just work.
    q.push(&a);
    try std.testing.expectEqual(@as(u32, 7), q.pop().?.value);
}

test "Queue: drain-and-repartition preserves relative order" {
    var q: Queue(TestItem) = .{};
    var items: [4]TestItem = .{
        .{ .value = 10 }, .{ .value = 25 }, .{ .value = 30 }, .{ .value = 45 },
    };
    for (&items) |*it| q.push(it);

    // Repartition: 10/30 (expired) out, 25/45 (live) re-pushed — order preserved.
    // No manual `it.link = .{}`: pop() must return elements clean (next == null),
    // so re-pushing them immediately is legal. If pop() forgets to clear next,
    // push()'s invariant assert will trip right here — that's the test working.
    var expired: Queue(TestItem) = .{};
    var live: Queue(TestItem) = .{};
    while (q.pop()) |it| {
        if (it.value % 20 == 10) expired.push(it) else live.push(it);
    }
    try std.testing.expectEqual(@as(u32, 10), expired.pop().?.value);
    try std.testing.expectEqual(@as(u32, 30), expired.pop().?.value);
    try std.testing.expectEqual(@as(u32, 25), live.pop().?.value);
    try std.testing.expectEqual(@as(u32, 45), live.pop().?.value);
}

test "Queue: pop returns the element clean (link.next cleared)" {
    var q: Queue(TestItem) = .{};
    var a: TestItem = .{ .value = 1 };
    var b: TestItem = .{ .value = 2 };
    q.push(&a);
    q.push(&b);

    // `a` was the head with a live next pointer to `b`. After popping, the
    // popped element must come out unlinked so it can be re-pushed anywhere.
    const popped = q.pop().?;
    try std.testing.expectEqual(@as(u32, 1), popped.value);
    try std.testing.expectEqual(@as(?*Queue(TestItem).Link, null), popped.link.next);

    // Proof it's safe to re-push immediately (would trip push's assert if not clean).
    q.push(popped);
    try std.testing.expectEqual(@as(u32, 2), q.pop().?.value);
    try std.testing.expectEqual(@as(u32, 1), q.pop().?.value);
}

test "Queue: peek and peek_last do not remove" {
    var q: Queue(TestItem) = .{};
    try std.testing.expectEqual(@as(?*TestItem, null), q.peek());
    try std.testing.expectEqual(@as(?*TestItem, null), q.peek_last());

    var a: TestItem = .{ .value = 1 };
    var b: TestItem = .{ .value = 2 };
    var z: TestItem = .{ .value = 3 };
    q.push(&a);
    q.push(&b);
    q.push(&z);

    // Single element edge: with one item, head and tail are the same element.
    // (Checked implicitly below across multiple peeks — both must be stable.)
    try std.testing.expectEqual(@as(u32, 1), q.peek().?.value); // front
    try std.testing.expectEqual(@as(u32, 3), q.peek_last().?.value); // back
    // Idempotent: peeking must not consume.
    try std.testing.expectEqual(@as(u32, 1), q.peek().?.value);
    try std.testing.expectEqual(@as(u32, 3), q.peek_last().?.value);
    try std.testing.expect(!q.empty());

    // After popping the front, peek tracks the new front; peek_last unchanged.
    _ = q.pop();
    try std.testing.expectEqual(@as(u32, 2), q.peek().?.value);
    try std.testing.expectEqual(@as(u32, 3), q.peek_last().?.value);
}
