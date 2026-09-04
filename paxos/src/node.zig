const std = @import("std");
const clock_lib = @import("clock.zig");

const Config = @import("config.zig").Config;
const IO = @import("io.zig").IO;
const Clock = clock_lib.Clock;
const RealClock = clock_lib.RealClock;
const Message = @import("message.zig").Message;
const MessageBus = @import("message_bus.zig").MessageBus;
const assert = std.debug.assert;

pub const NodeStats = struct {
    self_messages: u64 = 0,
    messages_received: u64 = 0,
};

pub const Node = struct {
    io: *IO,
    bus: MessageBus,
    config: Config,
    loopback: ?Message = null,
    stats: NodeStats = .{},
    callback: ?*const fn (node: *Node, message: Message) void = null,

    const Self = @This();

    pub fn init(
        self: *Self,
        io: *IO,
        config: Config,
        callback: ?*const fn (node: *Node, message: Message) void,
    ) !void {
        self.* = .{
            .io = io,
            .config = config,
            .bus = undefined,
            .loopback = null,
            .stats = .{},
            .callback = callback,
        };

        try self.bus.init(self.io, self.config, Self.on_message_from_bus);
    }

    pub fn deinit(self: *Self) void {
        self.bus.deinit();
    }

    fn on_message_from_bus(bus: *MessageBus, message: Message) void {
        const self: *Self = @fieldParentPtr("bus", bus);
        self.stats.messages_received += 1;
        self.on_message(message);
    }

    fn on_message(self: *Self, message: Message) void {
        // TODO: Pass to Paxos layer once it's in place.
        if (self.callback) |hook| {
            hook(self, message);
        }
    }

    pub fn tick(self: *Self) void {
        assert(self.loopback == null);
        self.bus.tick();
        assert(self.loopback == null);
    }

    pub fn broadcast(self: *Self, message: *const Message) void {
        for (0..self.config.cluster_size) |peer| {
            self.send_to_node(@intCast(peer), message);
        }
    }

    pub fn send_to_node(self: *Self, peer: u8, message: *const Message) void {
        assert(peer < self.config.cluster_size);

        if (peer == self.config.node_id) {
            assert(self.loopback == null);
            self.loopback = message.*;
        } else {
            self.bus.send_to(peer, message);
        }
    }

    pub fn flush_loopback(self: *Self) void {
        if (self.loopback) |message| {
            self.stats.self_messages += 1;
            self.loopback = null;
            self.on_message(message);
        }
        assert(self.loopback == null);
    }
};

const TestHarness = struct {
    const CAPACITY = 8;

    node: Node,
    messages: [CAPACITY]Message = undefined,
    count: usize = 0,

    fn on_message(node: *Node, message: Message) void {
        const self: *TestHarness = @fieldParentPtr("node", node);
        assert(self.count < CAPACITY);
        self.messages[self.count] = message;
        self.count += 1;
    }
};

test "Node init" {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    // Declared first so it runs last: the node's teardown closes sockets through the IO.
    defer io.deinit();

    var harness: TestHarness = .{ .node = undefined };
    const node = &harness.node;

    const config: Config = .{
        .node_id = 0,
        .cluster_size = 1,
        .base_port = 4000,
        .address = "127.0.0.1",
    };

    try node.init(&io, config, TestHarness.on_message);
    defer node.deinit();

    try std.testing.expectEqual(node.stats.messages_received, 0);
    try std.testing.expectEqual(node.stats.self_messages, 0);
    try std.testing.expect(node.loopback == null);
    try std.testing.expectEqual(@as(usize, 0), harness.count);
}

test "loopback test" {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    // Declared first so it runs last: the node's teardown closes sockets through the IO.
    defer io.deinit();

    var harness: TestHarness = .{ .node = undefined };
    const node = &harness.node;

    const config: Config = .{
        .node_id = 0,
        .cluster_size = 1,
        .base_port = 4000,
        .address = "127.0.0.1",
    };

    try node.init(&io, config, TestHarness.on_message);
    defer node.deinit();

    const message: Message = Message.init(.prepare, "Some Message", 0);
    node.send_to_node(0, &message);
    try std.testing.expect(node.loopback != null);
    try std.testing.expect(node.loopback.?.message_type == .prepare);

    node.flush_loopback();
    try std.testing.expect(node.loopback == null);
    try std.testing.expectEqual(@as(u64, 1), node.stats.self_messages);
    try std.testing.expectEqual(@as(u64, 0), node.stats.messages_received);

    // The callback saw exactly the message that went in — body included.
    try std.testing.expectEqual(@as(usize, 1), harness.count);
    try std.testing.expect(harness.messages[0].message_type == .prepare);
    try std.testing.expectEqual(@as(u16, 0), harness.messages[0].sender);
    try std.testing.expectEqualSlices(u8, &message.body, &harness.messages[0].body);
}

test "broadcast routes a self-message through the loopback" {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    // Declared first so it runs last: the node's teardown closes sockets through the IO.
    defer io.deinit();

    var harness: TestHarness = .{ .node = undefined };
    const node = &harness.node;

    const config: Config = .{
        .node_id = 0,
        .cluster_size = 1,
        .base_port = 4000,
        .address = "127.0.0.1",
    };

    try node.init(&io, config, TestHarness.on_message);
    defer node.deinit();

    const message: Message = Message.init(.prepare, "Broadcast Message", 0);
    node.broadcast(&message);
    try std.testing.expect(node.loopback != null);
    try std.testing.expect(node.loopback.?.message_type == .prepare);

    node.flush_loopback();
    try std.testing.expect(node.loopback == null);
    try std.testing.expectEqual(@as(u64, 1), node.stats.self_messages);
    try std.testing.expectEqual(@as(u64, 0), node.stats.messages_received);

    // The callback saw exactly the message that went in — body included.
    try std.testing.expectEqual(@as(usize, 1), harness.count);
    try std.testing.expect(harness.messages[0].message_type == .prepare);
    try std.testing.expectEqual(@as(u16, 0), harness.messages[0].sender);
    try std.testing.expectEqualSlices(u8, &message.body, &harness.messages[0].body);
}
