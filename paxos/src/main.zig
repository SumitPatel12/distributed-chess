const std = @import("std");
const stdIo = std.Io;
const build_options = @import("build_options");
const IO = @import("io.zig").IO;
const node_lib = @import("node.zig");
const Config = @import("config.zig").Config;
const _clock = @import("clock.zig");
const message_lib = @import("message.zig");

const Node = node_lib.Node;
const Message = message_lib.Message;
const MessageType = message_lib.MessageType;
const Clock = _clock.Clock;
const RealClock = _clock.RealClock;

var interrupted: std.atomic.Value(bool) = .init(false);

fn handle_sigint(_: std.c.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const NodeRunner = struct {
    const CAPACITY = 1024;

    node: Node,
    messages: [CAPACITY]Message = undefined,
    count: usize = 0,

    fn on_message(node: *Node, message: Message) void {
        const self: *NodeRunner = @fieldParentPtr("node", node);
        if (self.count == CAPACITY) {
            return;
        }

        self.messages[self.count] = message;
        self.count += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = stdIo.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    // Argument parsing a lot more of a pain than you'd imagine. Funny how we take things for
    // granted until we actually have to implement it.
    // I'm going for a copout, we get two positional arguments and parse them as u8.
    if (args.len != 3) {
        std.debug.print(
            "usage: {s} <node_id> <cluster_size>\n",
            .{args[0]},
        );
        std.process.exit(1);
    }

    const node_id: u8 = std.fmt.parseInt(u8, args[1], 10) catch {
        std.debug.print(
            "usage: {s} <node_id> <cluster_size>\n",
            .{args[0]},
        );
        std.process.exit(1);
    };

    const cluster_size: u8 = std.fmt.parseInt(u8, args[2], 10) catch {
        std.debug.print(
            "usage: {s} <node_id> <cluster_size>\n",
            .{args[0]},
        );
        std.process.exit(1);
    };

    if (cluster_size == 0 or cluster_size > build_options.cluster_size_max) {
        std.debug.print(
            "cluster_size must be an integer from 1 to {d}\n",
            .{build_options.cluster_size_max},
        );
        std.process.exit(1);
    }

    if (node_id >= cluster_size) {
        std.debug.print(
            "node_id must be an integer from 0 to {d}\n",
            .{cluster_size - 1},
        );
        std.process.exit(1);
    }

    try stdout.print(
        "paxos node {d} of {d}-node cluster\n",
        .{ node_id, cluster_size },
    );
    try stdout.flush();

    const config: Config = .{
        .address = "127.0.0.1",
        .base_port = 3000,
        .cluster_size = cluster_size,
        .node_id = node_id,
    };

    var mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&mask);

    const action: std.c.Sigaction = .{
        .mask = mask,
        .handler = .{ .handler = handle_sigint },
        .flags = 0,
    };

    _ = std.c.sigaction(std.c.SIG.INT, &action, null);

    try start_node(config);
}

fn start_node(config: Config) !void {
    var real_clock: RealClock = .{};
    const clock: Clock = .{ .real = &real_clock };

    var io: IO = .{ .clock = undefined };
    try io.init(clock);
    defer io.deinit();

    var runner: NodeRunner = .{ .node = undefined };
    const node = &runner.node;
    try node.init(&io, config, NodeRunner.on_message);
    defer node.deinit();

    var iteration: u48 = 0;
    const message_send_modulo: u48 = switch (config.node_id) {
        0 => 3,
        1 => 5,
        2 => 7,
        else => unreachable,
    };

    while (!interrupted.load(.acquire)) : (iteration += 1) {
        if (iteration % message_send_modulo == 0) {
            const epoch: u64 = (@as(u64, iteration) << 8) | config.node_id;
            var body: [8]u8 = undefined;
            std.mem.writeInt(u64, &body, epoch, .little);
            const message = Message.init(.prepare, &body, config.node_id);
            node.broadcast(&message);
            node.flush_loopback();
        }

        node.tick();
        try io.run_for_ns(10 * std.time.ns_per_ms);
    }

    std.debug.print(
        "Node: {d} Received: {d} Self: {d}\n",
        .{
            config.node_id,
            node.stats.messages_received,
            node.stats.self_messages,
        },
    );

    for (runner.messages[0..runner.count]) |*message| {
        const epoch = std.mem.readInt(u64, message.body[0..8], .little);
        std.debug.print(
            "From: {d} Message Type: {s} Iteration: {d} Node: {d}\n",
            .{
                message.sender,
                @tagName(message.message_type),
                epoch >> 8,
                @as(u8, @truncate(epoch)),
            },
        );
    }
}
