pub const IO = @import("io.zig").IO;

test {
    _ = @import("io.zig");
    _ = @import("queue.zig");
    _ = @import("clock.zig");
    _ = @import("syscalls.zig");
}
