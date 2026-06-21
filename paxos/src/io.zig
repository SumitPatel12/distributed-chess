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
        ops_submitted: u64 = 0,
        parks: u64 = 0,
        kevent_calls: u64 = 0,
        events_received: u64 = 0,
        callbacks_run: u64 = 0,
        timeouts_expired: u64 = 0,
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

        const on_complete = struct {
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
            .callback = on_complete,
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

    /// Queue a timeout operation
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
                min_remaining = if (min_remaining) |min_remaining_ns| @min(
                    min_remaining_ns,
                    remaining,
                ) else remaining;
                live_timeouts.push(completion);
            }
        }
        self.timeouts = live_timeouts;

        return min_remaining;
    }

    /// Create kevents for io_pending completions upto a max of `events.len`.
    pub fn flush_io(self: *Self, events: []c.Kevent) usize {
        for (events, 0..) |*event, i| {
            // If the queue is empty we've got the iternation number of events.
            const completion = self.io_pending.pop() orelse return i;

            const socket, const filters: i16 = switch (completion.operation) {
                .recv => |r| .{ r.socket, c.EVFILT.READ },
                .send => |s| .{ s.socket, c.EVFILT.WRITE },
                .accept => |a| .{ a.socket, c.EVFILT.READ },
                // We want to be notified when we can write to a connection. This got me at first.
                .connect => |conn| .{ conn.socket, c.EVFILT.WRITE },
                else => @panic("Unsupported operation encountered in flush_io."),
            };

            event.* = .{
                .ident = @intCast(socket),
                .filter = filters,
                .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
                .data = 0,
                .fflags = 0,
                .udata = @intFromPtr(completion),
            };
        }

        return events.len;
    }

    pub fn flush(self: *Self, wait_for_completion: bool) !void {
        assert(self.kq != -1);
        var events: [256]c.Kevent = undefined;

        const next_timeout = self.flush_timeouts();
        const change_events_count = self.flush_io(&events);

        // If we got no new changes and we do have some completions queued, we skip kevents. No
        // syscall overhead.
        if (change_events_count > 0 or self.completed.empty()) {
            var ts = std.mem.zeroes(c.timespec);

            // Both are empty so we're gonna see if we should have a timeout and register the
            // kevents or just return early because we have nothing to do.
            if (change_events_count == 0 and self.completed.empty()) {
                if (wait_for_completion) {
                    const timeout_ns = next_timeout orelse
                        @panic("kevent would block indefinitely.");
                    ts.sec = @intCast(timeout_ns / std.time.ns_per_s);
                    ts.nsec = @intCast(timeout_ns % std.time.ns_per_s);
                } else if (self.io_inflight == 0) {
                    // We've got no work to do so return early.
                    return;
                }
            }

            const blocked_start = self.clock.monotonic_ns();
            const events_ready = try syscalls.kevent(
                self.kq,
                events[0..change_events_count],
                events[0..],
                &ts,
            );
            self.stats.time_blocked_ns += self.clock.monotonic_ns() - blocked_start;
            self.stats.kevent_calls += 1;
            self.stats.events_received += @intCast(events_ready);

            self.io_inflight += @intCast(change_events_count);
            self.io_inflight -= @intCast(events_ready);

            for (events[0..events_ready]) |event| {
                const completion: *Completion = @ptrFromInt(event.udata);
                completion.link = .{};
                self.completed.push(completion);
            }
        }

        var completed_events = self.completed;
        self.completed.reset();

        self.stats.callbacks_run += @intCast(completed_events.count);
        const callbacks_start = self.clock.monotonic_ns();
        while (completed_events.pop()) |completed_event| {
            completed_event.callback(self, completed_event);
        }
        self.stats.time_callbacks_ns += self.clock.monotonic_ns() - callbacks_start;
    }

    pub fn run(self: *Self) !void {
        try self.flush(false);
    }

    pub fn run_for_ns(self: *Self, ns: u64) !void {
        var timed_out = false;
        var completion: Completion = undefined;

        const on_timeout = struct {
            fn on_timeout(timed_out_ptr: *bool, _: *Completion, _: void) void {
                timed_out_ptr.* = true;
            }
        }.on_timeout;

        self.timeout(*bool, &timed_out, on_timeout, &completion, ns);

        // Unbounded until the deadline fires. The above enqueued timout ensures this condition.
        while (!timed_out) {
            try self.flush(true);
        }
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

test "recv parks on WouldBlock, then resumes via kqueue and delivers bytes" {
    var fake_clock: FakeClock = .{};
    const clock: Clock = .{ .fake = &fake_clock };
    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    defer io.deinit();

    // A connected pair of sockets, in-process. A is the recv end, B the send end.
    var fds: [2]socket_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer syscalls.close(fds[0]);
    defer syscalls.close(fds[1]);

    // The recv end must be non-blocking, otherwise the optimistic recv blocks instead of parking.
    try syscalls.set_nonblock(fds[0]);

    const Result = struct { got: ?usize = null };
    var result: Result = .{};
    const on_recv = struct {
        fn on_recv(res: *Result, _: *IO.Completion, bytes: syscalls.RecvError!u31) void {
            res.got = bytes catch |err| std.debug.panic("recv failed: {}", .{err});
        }
    }.on_recv;

    var buffer: [32]u8 = undefined;
    var completion: IO.Completion = undefined;
    io.recv(*Result, &result, on_recv, &completion, fds[0], &buffer);

    // Tick 1: the optimistic recv finds no data, returns WouldBlock, and parks onto io_pending.
    try io.run();
    try std.testing.expectEqual(@as(u64, 1), io.stats.parks);
    try std.testing.expectEqual(@as(?usize, null), result.got);

    // Tick 2: the parked recv is drained from io_pending and registered with kqueue.
    try io.run();
    try std.testing.expectEqual(@as(u32, 1), io.io_inflight);
    try std.testing.expectEqual(@as(?usize, null), result.got);

    // Make end A readable.
    try std.testing.expectEqual(@as(u31, 4), try syscalls.send(fds[1], "ping", 0));

    // Drive until the recv wakes and delivers. Bounded so a bug cannot hang the test.
    var ticks: u32 = 0;
    while (result.got == null) : (ticks += 1) {
        try std.testing.expect(ticks < 100);
        try io.run();
    }

    try std.testing.expectEqual(@as(?usize, 4), result.got);
    try std.testing.expectEqual(@as(u32, 0), io.io_inflight);
    try std.testing.expectEqual(@as(u64, 1), io.stats.events_received);
}

test "TCP sockets listen, accept, recv, and send" {
    var fake_clock: FakeClock = .{};
    const test_clock: Clock = .{ .fake = &fake_clock };

    var io: IO = .{ .clock = undefined };
    try io.init(test_clock);
    defer io.deinit();

    const server = try syscalls.open_socket_tcp(false);
    try syscalls.listen(server, "127.0.0.1", 3000, 64);

    var completion: IO.Completion = undefined;
    const Connection = struct { connection_socket: socket_t };
    var connection: Connection = .{ .connection_socket = -1 };

    const accept_callback = struct {
        pub fn accept_callback(conn: *Connection, _: *IO.Completion, result: syscalls.AcceptError!socket_t) void {
            if (result) |socket| {
                conn.connection_socket = socket;
            } else |err| {
                std.debug.panic("Failed to connect to the socket, go error: {s}", .{@errorName(err)});
            }
        }
    }.accept_callback;

    io.accept(*Connection, &connection, accept_callback, &completion, server);
    try io.run();

    const peer_address = try syscalls.parse_address("127.0.0.1", 3000);
    const peer_socket: socket_t = try syscalls.open_socket_tcp(true);
    try syscalls.connect(peer_socket, &peer_address);

    // Drive the loop until the accept actually lands. A single run isn't guaranteed to have
    // resolved the accept. I see why the infinite loop and stuff.
    var accept_ticks: u8 = 0;
    while (connection.connection_socket < 0 and accept_ticks < 100) : (accept_ticks += 1) {
        try io.run();
    }
    try std.testing.expect(connection.connection_socket >= 0);

    const server_message = "This is a server message!?";
    const peer_message = "Well met, server. I'm the Master NOW!!";

    const SendContext = struct { bytes_sent: u32 = 0 };
    const RecvContext = struct { bytes_received: u32 = 0, bytes: [100]u8 = undefined };

    var send_context: SendContext = .{};
    var send_completion: IO.Completion = undefined;

    var recv_context: RecvContext = .{};
    var recv_completion: IO.Completion = undefined;

    const send_callback = struct {
        pub fn send_callback(ctx: *SendContext, _: *IO.Completion, result: syscalls.SendError!u31) void {
            if (result) |bytes_sent| {
                ctx.bytes_sent = bytes_sent;
            } else |err| {
                std.debug.panic("Failed to send message, go error: {s}", .{@errorName(err)});
            }
        }
    }.send_callback;

    const recv_callback = struct {
        pub fn recv_callback(ctx: *RecvContext, _: *IO.Completion, result: syscalls.RecvError!u31) void {
            if (result) |bytes_received| {
                ctx.bytes_received = bytes_received;
            } else |err| {
                std.debug.panic("Failed to receive message, go error: {s}", .{@errorName(err)});
            }
        }
    }.recv_callback;

    io.send(
        *SendContext,
        &send_context,
        send_callback,
        &send_completion,
        connection.connection_socket,
        server_message,
    );

    io.recv(
        *RecvContext,
        &recv_context,
        recv_callback,
        &recv_completion,
        connection.connection_socket,
        &recv_context.bytes,
    );

    // both send and rec will be parked at this point. Send should just have finished as it would
    // just write to a buffer and complete.
    try io.run();

    var peer_buffer: [100]u8 = undefined;
    const bytes_received = try syscalls.recv(peer_socket, &peer_buffer, 0);
    const bytes_sent = try syscalls.send(peer_socket, peer_message, 0);

    try std.testing.expectEqual(bytes_received, server_message.len);
    try std.testing.expectEqual(bytes_sent, peer_message.len);

    // Since the peer has responded they should be ready to be consumed now. A single zero-timeout
    // poll can miss bytes that haven't reached the recv buffer yet, so loop (bounded) until the
    // recv completes.
    var ticks: u8 = 0;
    while (recv_context.bytes_received == 0 and ticks < 100) : (ticks += 1) {
        try io.run();
    }

    try std.testing.expectEqual(recv_context.bytes_received, peer_message.len);
    try std.testing.expectEqualSlices(u8, peer_message, recv_context.bytes[0..recv_context.bytes_received]);
    try std.testing.expectEqual(send_context.bytes_sent, server_message.len);
}

// The fake clock never advances on its own, so the self-timeout in run_for_ns would never
// expire — this path can only be exercised with the real clock.
test "run_for_ns: real clock fires the deadline and the loop returns" {
    var real_clock: clock_lib.RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    defer io.deinit();

    const duration_ns: u64 = 2 * std.time.ns_per_ms;

    const start = clock.monotonic_ns();
    try io.run_for_ns(duration_ns);
    const elapsed = clock.monotonic_ns() - start;

    // kevent waits at least the deadline (it never returns early with no events registered),
    // so the wall clock must have advanced by at least the requested duration.
    try std.testing.expect(elapsed >= duration_ns);
    // The self-timeout was submitted once and expired exactly once.
    try std.testing.expectEqual(@as(u64, 1), io.stats.ops_submitted);
    try std.testing.expectEqual(@as(u64, 1), io.stats.timeouts_expired);
}
