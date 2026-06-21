pub const IO = @import("io.zig").IO;
// Exposed so echo.zig can build its listener (open_socket_tcp/listen) without re-rolling the
// raw socket calls. The "single seam" invariant (§5/§7) is relaxed for the echo proof only;
// post-echo these helpers should migrate behind IO and this re-export should go away.
pub const syscalls = @import("syscalls.zig");

test {
    _ = @import("io.zig");
    _ = @import("queue.zig");
    _ = @import("clock.zig");
    _ = @import("syscalls.zig");
}
