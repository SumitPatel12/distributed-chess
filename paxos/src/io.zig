//! Completion-shaped, single-threaded kqueue event loop for macOS/Darwin.
//!
//! Design spec: tmp/specs/kqueue-event-loop-design.html
//! Plan:        tmp/plans/kqueue-event-loop.md
//!
//! Production-only: the DST seam is the MessageBus, which is swapped wholesale
//! in simulation — this loop is never mocked. Zig 0.16, std.c raw externs only.

const std = @import("std");
const Clock = @import("clock.zig").Clock;
const Queue = @import("queue.zig").Queue;
const c = std.c;
const socket_t = std.c.fd_t;

pub const IO = struct {
    /// The kequeue fd. -1 implies not initiated.
    kq: i32 = -1,
    clock: Clock,
    io_inflight: u32 = 0,
    stats: Stats = .{},

    completed: Queue(Completion) = .{},
    io_pending: Queue(Completion) = .{},
    timeouts: Queue(Completion) = .{},

    pub const Stats = struct {
        ops_submitted: u32 = 0,
        parks: u32 = 0,
        kevent_calls: u32 = 0,
        events_harvested: u32 = 0,
        callbacks_run: u32 = 0,
        timeouts_expired: u32 = 0,
        time_blocked_ns: u64 = 0,
        time_callbacks_ns: u64 = 0,
    };

    pub const Operation = union(enum) {
        accept: struct { socket: socket_t },
        // Initiated is for checking on EISCONN
        connect: struct {
            socket: socket_t,
            address: c.sockaddr.in,
            initiated: bool,
        },
        recv: struct { socket: socket_t, buf: [*]u8, length: u32 },
        send: struct {
            socket: socket_t,
            buf: [*]const u8,
            length: u32,
        },
        timeout: struct { expire_ns: u64 },
        close: struct { fd: c.fd_t },
    };

    pub const Completion = struct {
        /// Intrusive linked list's link
        link: Queue(Completion).Link = .{},

        /// Caller state, type-erased, `submit`'s stamped `callback` casts it back to the concrete
        /// Context (@ptrCast/@alignCast).
        context: ?*anyopaque,

        /// Function to be called when the operations yields.
        callback: *const fn (*IO, *Completion) void,

        /// The operation for which the completion was fired.
        operation: Operation,
    };
};

test {
    std.testing.refAllDecls(@This());
}
