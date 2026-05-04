const std = @import("std");
const Io = std.Io;
const paxos = @import("paxos");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    // Argument parsing a lot more of a pain than you'd imagine. Funny how we take things for
    // granted until we actually have to implement it.
    // I'm going for a copout, we get only the first argument and parse it as a u32.
    const node_id: u8 = std.fmt.parseInt(u8, args[1], 10) catch {
        std.debug.print(
            "usage: {s} <node_id>",
            .{args[0]},
        );
        std.process.exit(1);
    };

    if (node_id > build_options.cluster_size) {
        std.debug.print(
            "node_id must be an integer from 0 to {d}\n",
            .{build_options.cluster_size},
        );
        std.process.exit(1);
    }

    try stdout.print(
        "paxos node {d} of {d}-node cluster\n",
        .{ node_id, build_options.cluster_size },
    );
    try stdout.flush();
}
