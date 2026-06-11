//! Module root for the paxos package.
//! Declared as the root source file by build.zig; everything reachable from
//! here is in the build graph (see tmp/zig-knowledge G2: an import alone does
//! not force analysis — the refAllDecls in each file's test block does).

pub const IO = @import("io.zig").IO;

test {
    _ = @import("io.zig");
    _ = @import("queue.zig");
    _ = @import("clock.zig");
    _ = @import("syscalls.zig");
}
