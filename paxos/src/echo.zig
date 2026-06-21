//! Dumb server that echoes back whatever you send it.
//! By echo we mean it sends back the same data over the connection.

const std = @import("std");
const io_lib = @import("io.zig");
const syscalls = @import("syscalls.zig");
const clock_lib = @import("clock.zig");

const assert = std.debug.assert;
const socket_t = std.c.fd_t;
const Completion = io_lib.IO.Completion;
const IO = io_lib.IO;
const Clock = clock_lib.Clock;
const RealClock = clock_lib.RealClock;

var interrupted: std.atomic.Value(bool) = .init(false);

const Connection = struct {
    socket: socket_t = -1,
    // The send/recv is going to be sequential for this one so they share a completion, for a
    // production usecase they should have their own completions. At a given time only one send
    // would be in place I think.
    completion: Completion = undefined,
    buffer: [1024]u8 = undefined,
    // Bytes echoed back to the peer is sequential: recv stamps message_len with the bytes it read,
    // and send advances total_sent until it catches up (handling partial sends).
    message_len: u31 = 0,
    total_sent: u31 = 0,
    state: enum { free, receiving, sending } = .free,
};

fn handle_sigint(_: std.c.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

// Just sends back whatever bytes it receives.
const EchoServer = struct {
    io: IO = undefined,
    // Socket the server listens on.
    socket: socket_t = -1,
    pool: [8]Connection = undefined,
    // Accept gets its own completion cause we can get different accept requests while a connection
    // is open and is going through the send/recv cycle.
    accept_completion: Completion = undefined,

    const Self = @This();

    pub fn init(self: *EchoServer, clock: Clock) !void {
        self.io = .{ .clock = undefined };
        try self.io.init(clock);

        self.socket = try syscalls.open_socket_tcp(false);
        try syscalls.listen(self.socket, "127.0.0.1", 3000, 64);

        self.pool = @splat(.{});

        var mask: std.c.sigset_t = undefined;
        _ = std.c.sigemptyset(&mask);

        const action: std.c.Sigaction = .{
            .mask = mask,
            .handler = .{ .handler = handle_sigint },
            .flags = 0,
        };

        _ = std.c.sigaction(std.c.SIG.INT, &action, null);
    }

    pub fn start(self: *Self) !void {
        assert(self.socket >= 0);
        self.io.accept(*EchoServer, self, accept_callback, &self.accept_completion, self.socket);

        while (!interrupted.load(.acquire)) {
            try self.io.run_for_ns(std.time.ns_per_ms * 10);
        }

        std.debug.print("stats: {any}\n", .{self.io.stats});
    }

    pub fn accept_callback(
        server: *EchoServer,
        completion: *Completion,
        result: syscalls.AcceptError!socket_t,
    ) void {
        if (result) |socket| {
            // Find an empty slot in the pool.
            const slot: ?*Connection = for (&server.pool) |*connection| {
                if (connection.state == .free) {
                    break connection;
                }
            } else null;

            // If we've got a slot, take it and send a message off of it.
            if (slot) |connection| {
                connection.socket = socket;
                server.recv(connection);
            } else {
                // If we don't got an empty one requeue the accept, likely something will open up in
                // the future.
                std.debug.print("Pool full ({d}), rejecting connection\n", .{server.pool.len});
                syscalls.close(socket);
            }
        } else |err| {
            std.debug.print("Error during accept: {t}\n", .{err});
        }

        // The server should keep listening cause connection are dynamic, and can keep closing and
        // opening.
        server.io.accept(
            *EchoServer,
            server,
            accept_callback,
            completion,
            server.socket,
        );
    }

    pub fn recv_callback(
        server: *EchoServer,
        completion: *Completion,
        result: syscalls.RecvError!u31,
    ) void {
        const connection: *Connection = @fieldParentPtr("completion", completion);
        assert(connection.state == .receiving);

        if (result) |bytes_received| {
            assert(bytes_received <= connection.buffer.len);

            // 0 bytes means the connectino was closed, and we need to close our side of the
            // connection as well.
            if (bytes_received == 0) {
                std.debug.print("Connection closed by peer\n", .{});
                server.close(connection);
            } else {
                std.debug.print("Received message: {s}\n", .{connection.buffer[0..bytes_received]});
                server.echo_back(connection, bytes_received);
            }
        } else |err| {
            std.debug.print("Error during recv: {t}\n", .{err});
            server.close(connection);
        }
    }

    pub fn send_callback(
        server: *EchoServer,
        completion: *Completion,
        result: syscalls.SendError!u31,
    ) void {
        const connection: *Connection = @fieldParentPtr("completion", completion);
        assert(connection.state == .sending);

        if (result) |bytes_sent| {
            std.debug.print("Bytes Sent: {d}\n", .{bytes_sent});

            connection.total_sent += bytes_sent;
            assert(connection.total_sent <= connection.message_len);

            // Partial send: more of this message still to go, so re-send the remainder. Only once
            // the whole message is out do we loop back to receiving the next one.
            if (connection.total_sent < connection.message_len) {
                server.send(connection);
            } else {
                server.recv(connection);
            }
        } else |err| {
            std.debug.print("Error during send: {t}\n", .{err});
            server.close(connection);
        }
    }

    pub fn recv(self: *Self, connection: *Connection) void {
        connection.state = .receiving;

        self.io.recv(
            *EchoServer,
            self,
            recv_callback,
            &connection.completion,
            connection.socket,
            &connection.buffer,
        );
    }
    pub fn echo_back(self: *Self, connection: *Connection, len: u31) void {
        connection.message_len = len;
        connection.total_sent = 0;
        self.send(connection);
    }

    pub fn send(self: *Self, connection: *Connection) void {
        assert(connection.total_sent <= connection.message_len);
        connection.state = .sending;
        self.io.send(
            *EchoServer,
            self,
            send_callback,
            &connection.completion,
            connection.socket,
            connection.buffer[connection.total_sent..connection.message_len],
        );
    }

    pub fn close(_: *Self, connection: *Connection) void {
        syscalls.close(connection.socket);
        connection.state = .free;
    }

    pub fn deinit(self: *Self) void {
        for (&self.pool) |*connection| {
            if (connection.state != .free) syscalls.close(connection.socket);
        }
        syscalls.close(self.socket);
        self.io.deinit();
    }
};

pub fn main() !void {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var server: EchoServer = .{};
    try server.init(clock);
    defer server.deinit();

    try server.start();
}
