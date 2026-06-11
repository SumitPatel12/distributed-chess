const std = @import("std");
const assert = std.debug.assert;
const c = std.c;

extern "c" fn clock_gettime_nsec_np(clock_id: std.c.clockid_t) u64;

pub const RealClock = struct {
    const Self = @This();
    pub fn monotonic_ns(self: Self) u64 {
        _ = self;
        return clock_gettime_nsec_np(.MONOTONIC_RAW);
    }
};

/// Fake clock used to drie the clock ticks and other time derived mechanics for the DST harness.
pub const FakeClock = struct {
    current_time: u64 = 0,

    const Self = @This();

    pub fn monotonic_ns(self: Self) u64 {
        return self.current_time;
    }

    pub fn advance_ns(self: *Self, advance: u64) void {
        self.current_time += advance;
    }
};

/// Will be the clock entity used throughout the Paxos implementation. DST harness will use the fake
/// clock, while the production will use the real clock.
pub const Clock = union(enum) {
    real: *RealClock,
    fake: *FakeClock,

    const Self = @This();

    /// Nanoseconds from a monotonic source, is dependent on the system and is not the real time.
    /// Only used to measure elapsed time, and is not to be used for timestamping.
    pub fn monotonic_ns(self: Self) u64 {
        return switch (self) {
            .real => |r| r.monotonic_ns(),
            .fake => |f| f.monotonic_ns(),
        };
    }

    /// Advance the fake clock by given ns.
    pub fn advance_ns(self: Self, advance: u64) void {
        switch (self) {
            .real => @panic("Cannot advance real clock"),
            .fake => |f| f.advance_ns(advance),
        }
    }
};

// ── tests ─────────────────────────────────────────────────────────────────────

test "FakeClock: a Clock view sees advances to the owned clock" {
    var fake = FakeClock{}; // the harness owns this
    const clock = Clock{ .fake = &fake }; // a subsystem holds a view
    try std.testing.expectEqual(@as(u64, 0), clock.monotonic_ns());
    try std.testing.expectEqual(@as(u64, 0), clock.monotonic_ns()); // no drift between reads
    fake.advance_ns(150); // advance the OWNED clock, not the view
    try std.testing.expectEqual(@as(u64, 150), clock.monotonic_ns()); // the view sees it
}

test "RealClock: nonzero and non-decreasing" {
    var real = RealClock{};
    const clock = Clock{ .real = &real };
    const t1 = clock.monotonic_ns();
    const t2 = clock.monotonic_ns();
    try std.testing.expect(t1 > 0);
    try std.testing.expect(t2 >= t1);
}
