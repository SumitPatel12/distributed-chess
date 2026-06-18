const std = @import("std");
const syscalls = @import("syscalls.zig");
const clock_lib = @import("clock.zig");
const Clock = clock_lib.Clock;
const FakeClock = clock_lib.FakeClock;
const Queue = @import("queue.zig").Queue;
const c = std.c;
const socket_t = std.c.fd_t;
const assert = std.debug.assert;

// This will end up looking very similar to what TigerBeetle has since I'm learning off of what they
// did. And, boy, is it difficult, especially the submit and other opertaion functions, it making
// it's own closure type things, using kevent udata to piggyback context and all. ['']/
pub const IO = struct {
    /// The kequeue fd. -1 implies not initiated.
    kq: i32 = -1,
    clock: Clock,
    io_inflight: u32 = 0,
    stats: Stats = .{},

    /// Holds the completions that are ready to run during the next flush.
    completed: Queue(Completion) = .{},
    /// Holds the completions that would have blocked.
    io_pending: Queue(Completion) = .{},
    timeouts: Queue(Completion) = .{},

    const Self = @This();

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
        recv: struct {
            socket: socket_t,
            buffer: [*]u8,
            len: u32,
        },
        send: struct {
            socket: socket_t,
            buffer: [*]const u8,
            len: u32,
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

    pub fn init(self: *Self, clock: Clock) !void {
        assert(self.kq == -1);
        const kq = try syscalls.kqueue();

        self.* = .{
            .kq = kq,
            .clock = clock,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.kq != -1);
        syscalls.close(self.kq);
        self.kq = -1;
    }

    fn submit(
        self: *Self,
        // Kinda seems like we're trying to write our own closure or something.
        /// Pointer to the caller's state erased to ?*anyopaque when stored in the Completion. The
        /// callback casts it back to mutate that state once the op completes.
        context: anytype,
        // The context casting works here because callback is comptime known and we therefore know
        // what to cast the context back to during runtime. Tryly a piece of work here by
        // TigerBeetle
        /// Function called on completion (be it success or error). If it would be blocked we park
        /// it instead of calling this function.
        comptime callback: anytype,
        /// Caller allocated completion that will be populated with callback, context, and operation
        completion: *Completion,
        /// The operation that is to be performed one of the Operation tagged union
        comptime operation_tag: std.meta.Tag(Operation),
        /// The payload of that operation as specified in the tagged union
        operation_data: @FieldType(Operation, @tagName(operation_tag)),
        /// Carries the do_operation function that does the actual syscall for the operation
        comptime OperationImpl: type,
    ) void {
        assert(self.kq != -1);

        const on_complete_fn = struct {
            /// Perform the operation and run the callback. Parks in io_pending if the operation
            /// return a WouldBlock.
            fn on_complete(io: *IO, _completion: *Completion) void {
                // Restore the operation's type and perform that operation. operation_tag is
                // comptime known is the reason why we can do it like this.
                const operation = &@field(_completion.operation, @tagName(operation_tag));
                const result = OperationImpl.do_operation(operation);

                // Park the action if it would block
                switch (operation_tag) {
                    .accept, .connect, .recv, .send => {
                        _ = result catch |err| switch (err) {
                            error.WouldBlock => {
                                io.stats.parks += 1;
                                _completion.link = .{};
                                io.io_pending.push(_completion);
                                return;
                            },
                            else => {},
                        };
                    },
                    else => {},
                }

                // Everything was all right so we proceed with the callback, and pass the result as
                // well, since result could be an error other than WouldBlock.
                return callback(@ptrCast(@alignCast(_completion.context)), _completion, result);
            }
        }.on_complete;

        completion.* = .{
            .link = .{},
            .context = context,
            .callback = on_complete_fn,
            .operation = @unionInit(Operation, @tagName(operation_tag), operation_data),
        };

        self.stats.ops_submitted += 1;
        switch (operation_tag) {
            .timeout => self.timeouts.push(completion),
            else => self.completed.push(completion),
        }
    }

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, syscalls.RecvError!u31) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []u8,
    ) void {
        assert(buffer.len <= std.math.maxInt(u32));

        self.submit(
            context,
            callback,
            completion,
            .recv,
            .{ .socket = socket, .buffer = buffer.ptr, .len = @intCast(buffer.len) },
            struct {
                pub fn do_operation(op: anytype) syscalls.RecvError!u31 {
                    return syscalls.recv(op.socket, op.buffer[0..op.len], 0);
                }
            },
        );
    }

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, syscalls.SendError!u31) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []const u8,
    ) void {
        assert(buffer.len <= std.math.maxInt(u32));

        self.submit(
            context,
            callback,
            completion,
            .send,
            .{ .socket = socket, .buffer = buffer.ptr, .len = @intCast(buffer.len) },
            struct {
                pub fn do_operation(op: anytype) syscalls.SendError!u31 {
                    return syscalls.send(op.socket, op.buffer[0..op.len], 0);
                }
            },
        );
    }

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, void) void,
        completion: *Completion,
        fd: c.fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .close,
            .{ .fd = fd },
            struct {
                pub fn do_operation(op: anytype) void {
                    return syscalls.close(op.fd);
                }
            },
        );
    }

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, syscalls.ConnectError!void) void,
        completion: *Completion,
        socket: socket_t,
        address: c.sockaddr.in,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .connect,
            .{ .socket = socket, .address = address, .initiated = false },
            struct {
                pub fn do_operation(op: anytype) syscalls.ConnectError!void {
                    const result = switch (op.initiated) {
                        // For the first time we call connect and all other times we check it's gone
                        // through or not. get_socket_error checks for that.
                        false => syscalls.connect(op.socket, &op.address),
                        true => syscalls.get_socket_error(op.socket),
                    };

                    // Once we're through here, the first pass is guaranteed done, so we always set
                    // the initiated to true.
                    op.initiated = true;
                    return result;
                }
            },
        );
    }

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, syscalls.AcceptError!socket_t) void,
        completion: *Completion,
        socket: socket_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .accept,
            .{ .socket = socket },
            struct {
                // The peer address should already be known via some config so we're free to ignore
                // it.
                pub fn do_operation(op: anytype) syscalls.AcceptError!socket_t {
                    return syscalls.accept(op.socket, null, false);
                }
            },
        );
    }

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, void) void,
        completion: *Completion,
        duration: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .timeout,
            // The consumers only need to provide the duration for which the timeout needs to last,
            // we'll stamp it to the actual deadline. Makes things easier and we don't need to dump
            // clock everywhere.
            .{ .expire_ns = self.clock.monotonic_ns() + duration },
            struct {
                // Timeout just needs to queue this operation in the timeouts queue, so the
                // do_operation is a no-op.
                pub fn do_operation(op: anytype) void {
                    _ = op;
                }
            },
        );
    }

    /// Queues any expired timeouts to completed queue, removes them from the timeouts queue and
    /// returns the min_time in ns required to wait for the next timeouts completion. If no more
    /// timeouts are present, then it returns `null`.
    pub fn flush_timeouts(self: *Self) ?u64 {
        var min_remaining: ?u64 = null;
        const now = self.clock.monotonic_ns();
        // TODO: There's likely a better method to do this than creating another queue, likely
        // something inplace.
        var live_timeouts: Queue(Completion) = .{};

        while (self.timeouts.pop()) |completion| {
            const expire_ns = completion.operation.timeout.expire_ns;
            completion.link = .{};
            if (expire_ns <= now) {
                self.stats.timeouts_expired += 1;
                self.completed.push(completion);
            } else {
                const remaining = expire_ns - now;
                min_remaining = if (min_remaining) |min_remaining_ns| @min(min_remaining_ns, remaining) else remaining;
                live_timeouts.push(completion);
            }
        }
        self.timeouts = live_timeouts;

        return min_remaining;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "flush_timeouts: completion flush over timeperiod" {
    var fake_clock: FakeClock = .{};
    const clock: Clock = .{ .fake = &fake_clock };
    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    defer io.deinit();

    const no_op = struct {
        fn no_op(_: ?*anyopaque, _: *IO.Completion, _: void) void {}
    }.no_op;

    // Undefined cause the submit call overwrites the whole thing anyways. No need to wire up mocks
    // which get overwritten.
    var completion_1: IO.Completion = undefined;
    var completion_2: IO.Completion = undefined;

    io.timeout(?*anyopaque, null, no_op, &completion_1, 100);
    io.timeout(?*anyopaque, null, no_op, &completion_2, 200);

    var next = io.flush_timeouts();
    try std.testing.expectEqual(next, 100);
    try std.testing.expectEqual(@as(usize, 2), io.timeouts.count);

    clock.advance_ns(150);
    next = io.flush_timeouts();
    try std.testing.expectEqual(next, 50);
    try std.testing.expectEqual(io.stats.timeouts_expired, 1);
    try std.testing.expectEqual(@as(usize, 1), io.timeouts.count);
}

test "flush_timeouts: a zero-duration timeout is immediately ready" {
    var fake_clock: FakeClock = .{};
    const clock: Clock = .{ .fake = &fake_clock };
    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    defer io.deinit();

    const no_op = struct {
        fn no_op(_: ?*anyopaque, _: *IO.Completion, _: void) void {}
    }.no_op;

    var completion: IO.Completion = undefined;
    io.timeout(?*anyopaque, null, no_op, &completion, 0);

    // No special-casing in timeout(): a zero duration is stamped expire_ns == now and queued like
    // any other timer.
    try std.testing.expectEqual(@as(usize, 1), io.timeouts.count);

    // The very first flush sees expire_ns (0) <= now (0), so it is already expired: it moves to
    // completed, nothing remains pending, and there is no min-remaining to wait on.
    const next = io.flush_timeouts();
    try std.testing.expectEqual(@as(?u64, null), next);
    try std.testing.expectEqual(@as(usize, 0), io.timeouts.count);
    try std.testing.expectEqual(@as(usize, 1), io.completed.count);
    try std.testing.expectEqual(@as(u32, 1), io.stats.timeouts_expired);
}
