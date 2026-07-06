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
};

pub const Node = struct {
    io: IO,
    bus: MessageBus,
    config: Config,
    loopback: ?Message = null,
    stats: NodeStats = .{},

    const Self = @This();

    pub fn init(
        self: *Self,
        clock: Clock,
        node_id: u16,
        cluster_size: u16,
    ) !void {
        self.bus = .{
            .io = undefined,
            .config = undefined,
            .socket = -1,
            .on_message_callback = undefined,
        };

        self.config = .{
            .address = "127.0.0.1",
            .base_port = 4000,
            .cluster_size = cluster_size,
            .node_id = node_id,
        };

        self.io = .{ .clock = undefined };

        self.loopback = null;

        try self.io.init(clock);
        errdefer self.io.deinit();

        try self.bus.init(&self.io, self.config, Self.on_message);
        errdefer self.bus.deinit();
    }

    pub fn deinit(self: *Self) void {
        self.bus.deinit();
        self.io.deinit();
    }

    pub fn on_message(bus: *MessageBus, message: Message) void {
        _ = message;
        const self: *Self = @fieldParentPtr("bus", bus);
        self.stats.self_messages += 1;
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

    pub fn send_to_node(self: *Self, peer: u16, message: *const Message) void {
        if (peer == self.config.node_id) {
            assert(self.loopback == null);
            self.loopback = message.*;
        } else {
            self.bus.send_to(peer, message);
        }
    }

    fn flush_loopback(self: *Self) void {
        if (self.loopback) |message| {
            self.loopback = null;
            Self.on_message(&self.bus, message);
        }
        assert(self.loopback == null);
    }
};

test "loopback test" {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var node: Node = .{
        .io = undefined,
        .bus = undefined,
        .config = undefined,
    };

    try node.init(clock, 0, 1);
    defer node.deinit();

    const message: Message = Message.init(.prepare, "Some Message", 0);
    node.send_to_node(0, &message);
    try std.testing.expect(node.loopback != null);
    try std.testing.expect(node.loopback.?.message_type == .prepare);

    node.flush_loopback();
    try std.testing.expect(node.loopback == null);
    try std.testing.expectEqual(@as(u64, 1), node.stats.self_messages);
}

test "broadcast routes a self-message through the loopback" {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var node: Node = .{
        .io = undefined,
        .bus = undefined,
        .config = undefined,
    };

    try node.init(clock, 0, 1);
    defer node.deinit();

    const message: Message = Message.init(.prepare, "Broadcast Message", 0);
    node.broadcast(&message);
    try std.testing.expect(node.loopback != null);
    try std.testing.expect(node.loopback.?.message_type == .prepare);

    node.flush_loopback();
    try std.testing.expect(node.loopback == null);
    try std.testing.expectEqual(@as(u64, 1), node.stats.self_messages);
}
