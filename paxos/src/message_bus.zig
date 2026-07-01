const std = @import("std");
const io_lib = @import("io.zig");
const cluster_size = @import("build_options").cluster_size;
const syscalls = @import("syscalls.zig");

const Config = @import("config.zig").Config;
const Message = @import("message.zig").Message;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const IO = io_lib.IO;
const Completion = io_lib.IO.Completion;
const socket_t = std.c.fd_t;
const assert = std.debug.assert;

pub const MessageBus = struct {
    io: *IO,

    config: Config,

    /// Represents the connection for the cluster. Each node is connected to every other node in the
    /// cluster.
    connections: [cluster_size]Connection = @splat(.{}),

    /// To keep indexing easy each node is indexed by it's id, and the current node's connection
    /// remains null.
    nodes: [cluster_size]?*Connection = @splat(null),

    /// Current node's listening socket.
    socket: socket_t,

    /// The accept syscall completion that keeps getting re-armed on the current nodes socket.
    accept_completion: Completion = undefined,

    accept_connection: ?*Connection = null,

    /// Stores the self votes for the Paxos alignment
    loopback: RingBuffer(Message, 16) = .{},

    // We could do something like passing the ?*anyopaque like in the io but that was because we
    // didn't have the info, for bus we do have it available so no need to go that route.
    //
    /// The function to be called when the bus receives a message from a node. The bus pointer is
    /// passed to recover the node using `fieldParentPointer`; the messge bus is embedded in the
    /// node itself.
    on_message: *const fn (*MessageBus, Message) void,

    const Self = @This();

    const Connection = struct {
        /// The peer node's id. Is null until a message is actually first received on the
        /// connection. Accept grabs the first empty connection and on the first message recv we'll
        /// populate it to the correct position in the nodes array, OR, if this node is initiating
        /// the connection it'll set the peer's id correctly from the config.
        peer: ?u16 = null,

        /// Socket over which the communication will be happening for this connection.
        socket: socket_t = -1,

        /// Queue of messages to be sent to this connection. Send will keep dequeuing off of this.
        send_buffer: RingBuffer(Message, 16) = .{},

        /// Tracks if there is any active recv parked. Used to indicate that there is some event in
        /// the IO loop which will come back and try to access this connection thus this connection
        /// cannot be terminated directly.
        recv_submitted: bool = false,
        recv_completion: Completion = undefined,
        recv_buffer: [Message.size]u8 = undefined,

        /// Tracks if there is any active send parked. Used to indicate that there is some event in
        /// the IO loop which will come back and try to access this connection thus this connection
        /// cannot be terminated directly.
        send_submitted: bool = false,
        send_completion: Completion = undefined,
        /// Holds the raw byte format of the message to be sent over the wire.
        send_message: [32]u8 = undefined,

        /// Tracks how many of the bytes to be received have been received so far. Messages are
        /// fixed 32 bytes so u8 suffices here.
        total_recv: u8 = 0,

        /// Tracks how many of the bytes to be sent have been sent so far. Messages are
        /// fixed 32 bytes so u8 suffices here.
        total_sent: u8 = 0,

        /// Current state of the connection.
        state: enum { free, accepting, connecting, connected, terminating } = .free,
    };

    /// Inline initialze the `MessageBus`. Opens the socket in non-blocking mode.
    /// Doesn't start listening yet.
    pub fn init(self: *Self, io: *IO, config: Config, on_message: *const fn (*MessageBus, Message) void) !void {
        const socket = try syscalls.open_socket_tcp(false);
        try syscalls.listen(
            socket,
            config.address,
            config.base_port + config.node_id,
            cluster_size - 1,
        );

        self.* = .{
            .io = io,
            .config = config,
            .socket = socket,
            .on_message = on_message,
        };
    }

    pub fn deinit(bus: *Self) void {
        bus.io.close_socket(bus.socket);

        for (&bus.connections) |*connection| {
            if (connection.socket != -1) {
                bus.io.close_socket(connection.socket);
            }
        }
    }

    pub fn tick(bus: *Self) void {
        if (bus.accept_connection == null) {
            const reserved: ?*Connection = for (&bus.connections) |*conn| {
                if (conn.state == .free) {
                    break conn;
                }
            } else null;

            if (reserved) |conn| {
                conn.state = .accepting;
                bus.accept_connection = conn;
                bus.io.accept(
                    *Self,
                    bus,
                    on_accept,
                    &bus.accept_completion,
                    bus.socket,
                );
            }
        }

        for (bus.config.node_id + 1..cluster_size) |id| {
            if (bus.nodes[id] == null) {
                bus.connect(@intCast(id));
            }
        }
    }

    fn terminate(bus: *Self, connection: *Connection) void {
        if (connection.state == .terminating) {
            return;
        }

        connection.state = .terminating;
        bus.terminate_join(connection);
    }

    fn terminate_join(bus: *Self, connection: *Connection) void {
        assert(connection.state == .terminating);

        // There's still some operatoins on this socket we wait until those are done
        if (connection.recv_submitted or connection.send_submitted) {
            return;
        }

        bus.terminate_close(connection);
    }

    fn terminate_close(bus: *MessageBus, connection: *Connection) void {
        assert(connection.state == .terminating);
        assert(connection.recv_submitted == false and connection.send_submitted == false);

        connection.send_submitted = true;
        const fd = connection.socket;
        connection.socket = -1;
        bus.io.close(
            *MessageBus,
            bus,
            close_callback,
            &connection.send_completion,
            fd,
        );
    }

    fn close_callback(bus: *MessageBus, completion: *Completion, _: void) void {
        const connection: *Connection = @fieldParentPtr("send_completion", completion);
        assert(connection.state == .terminating);

        if (connection.peer) |peer_id| {
            if (bus.nodes[peer_id] == connection) {
                bus.nodes[peer_id] = null;
            }
        }

        connection.* = .{};
    }

    fn connect(bus: *Self, peer_node_id: u16) void {
        // A node only initiates connections with nodes of higher id, that way we don't open two
        // connection between a pair.
        assert(bus.config.node_id < peer_node_id);
        assert(bus.nodes[peer_node_id] == null);

        const address = syscalls.parse_address(
            bus.config.address,
            bus.config.base_port + peer_node_id,
        ) catch {
            // TODO: Maybe log?
            return;
        };

        const connection: ?*Connection = for (&bus.connections) |*conn| {
            if (conn.state == .free) {
                break conn;
            }
        } else null;

        if (connection) |conn| {
            conn.state = .connecting;
            conn.socket = syscalls.open_socket_tcp(false) catch {
                conn.* = .{};
                // TODO: Maybe log?
                return;
            };
            conn.peer = peer_node_id;
            bus.nodes[peer_node_id] = conn;

            assert(!conn.recv_submitted);
            conn.recv_submitted = true;
            bus.io.connect(
                *MessageBus,
                bus,
                connect_callback,
                &conn.recv_completion,
                conn.socket,
                address,
            );
        } else {
            // TODO: Log?
        }
    }

    fn connect_callback(
        bus: *MessageBus,
        completion: *Completion,
        result: syscalls.ConnectError!void,
    ) void {
        const connection: *Connection = @fieldParentPtr(
            "recv_completion",
            completion,
        );
        connection.recv_submitted = false;

        if (connection.state == .terminating) {
            bus.terminate_join(connection);
            return;
        }

        if (result) |_| {
            assert(connection.peer != null);
            connection.state = .connected;

            bus.recv(connection);
            bus.send(connection);
        } else |_| {
            bus.terminate(connection);
        }
    }

    fn on_accept(
        bus: *MessageBus,
        _: *Completion,
        result: syscalls.AcceptError!socket_t,
    ) void {
        assert(bus.accept_connection != null);
        const connection: *Connection = bus.accept_connection.?;
        bus.accept_connection = null;
        assert(connection.state == .accepting);

        if (result) |connection_socket| {
            connection.state = .connected;
            connection.socket = connection_socket;

            bus.recv(connection);
        } else |_| {
            // TODO: Log failure.
            connection.* = .{};
        }
    }

    fn recv(bus: *Self, connection: *Connection) void {
        assert(connection.state == .connected);
        assert(connection.recv_submitted == false);

        connection.recv_submitted = true;

        // The context needs to be the message bus cause if we didn't read the whole thing then we
        // need access to the bus so we can re-queue the recv request. The connection can be
        // restored from the completion.
        bus.io.recv(
            *MessageBus,
            bus,
            recv_callback,
            &connection.recv_completion,
            connection.socket,
            // total_recv would be zero here.
            connection.recv_buffer[connection.total_recv..],
        );
    }

    fn recv_callback(
        bus: *MessageBus,
        completion: *Completion,
        result: syscalls.RecvError!u31,
    ) void {
        const connection: *Connection = @fieldParentPtr("recv_completion", completion);
        connection.recv_submitted = false;

        if (connection.state == .terminating) {
            bus.terminate_join(connection);
            return;
        }

        if (result) |bytes_read| {
            // Connection closed by the peer.
            if (bytes_read == 0) {
                bus.terminate(connection);
                return;
            }

            connection.total_recv += @intCast(bytes_read);
            assert(connection.total_recv <= Message.size);

            if (connection.total_recv == Message.size) {
                // Parse the message and send it to the owner of the message bus.
                const message: Message = Message.decode(&connection.recv_buffer) catch {
                    bus.terminate(connection);
                    return;
                };

                if (connection.peer == null) {
                    if (message.sender >= cluster_size or message.sender == bus.config.node_id) {
                        bus.terminate(connection);
                        return;
                    }

                    // There's an open connection that's for the current sender so we close it,
                    // and mark the current connection as the new one.
                    if (bus.nodes[message.sender]) |old| {
                        if (old != connection and old.state != .terminating) {
                            bus.terminate(old);
                        }
                    }

                    connection.peer = message.sender;
                    bus.nodes[message.sender] = connection;
                }

                bus.on_message(bus, message);
                connection.total_recv = 0;
            }

            // We got to be ready to recv the thing man.
            bus.recv(connection);
        } else |_| {
            // TODO: Better error handling
            bus.terminate(connection);
        }
    }

    fn send_to(bus: *Self, message: *const Message, peer: u16) void {
        assert(peer != bus.config.node_id);
        const connection = bus.nodes[peer] orelse return;

        if (connection.state == .terminating) {
            return;
        }

        connection.send_buffer.push(message.*) catch {
            return;
        };

        // We queue the message but it fires only after state is .connected.
        if (connection.state == .connecting) {
            return;
        }

        assert(connection.state == .connected);
        if (!connection.send_submitted) {
            bus.send(connection);
        }
    }

    fn send(bus: *Self, connection: *Connection) void {
        assert(connection.state == .connected);
        assert(connection.send_submitted == false);

        // If the buffer is empty we return early.
        const message = connection.send_buffer.peek() orelse return;

        if (connection.total_sent == 0) {
            message.encode(&connection.send_message);
        }

        connection.send_submitted = true;

        bus.io.send(
            *MessageBus,
            bus,
            send_callback,
            &connection.send_completion,
            connection.socket,
            connection.send_message[connection.total_sent..],
        );
    }

    fn send_callback(
        bus: *MessageBus,
        completion: *Completion,
        result: syscalls.SendError!u31,
    ) void {
        const connection: *Connection = @fieldParentPtr("send_completion", completion);
        connection.send_submitted = false;

        if (connection.state == .terminating) {
            bus.terminate_join(connection);
            return;
        }

        if (result) |bytes_sent| {
            connection.total_sent += @intCast(bytes_sent);
            assert(connection.total_sent <= Message.size);

            if (connection.total_sent == Message.size) {
                _ = connection.send_buffer.pop();
                connection.total_sent = 0;
            }

            bus.send(connection);
        } else |_| {
            bus.terminate(connection);
        }
    }
};

pub fn main() void {}

test {
    std.testing.refAllDecls(MessageBus);
}
