const std = @import("std");
const terminal_io = @import("terminal_io");
const chess_board = @import("chess_board");
const Position = chess_board.Position;

const ITERATIONS = 1000;

// Inter-frame delay in nanoseconds. Simulates a real display refresh interval so the terminal
// actually renders each frame and CPU caches cool between iterations. 16ms ≈ 60Hz.
const FRAME_DELAY_NS: u64 = 16 * std.time.ns_per_ms;

// A short sequence of legal opening moves cycled through during the benchmark.
// Each entry is a (from, to) pair of board positions. The sequence wraps every
// 6 iterations, and the board is reset to the starting position at the start
// of each cycle so every set of moves is applied to a valid board state.
const moves = [_][2]Position{
    .{ .{ .rank = 1, .file = 3 }, .{ .rank = 3, .file = 3 } },
    .{ .{ .rank = 6, .file = 3 }, .{ .rank = 4, .file = 3 } },
    .{ .{ .rank = 1, .file = 2 }, .{ .rank = 3, .file = 2 } },
    .{ .{ .rank = 6, .file = 4 }, .{ .rank = 5, .file = 4 } },
    .{ .{ .rank = 0, .file = 1 }, .{ .rank = 2, .file = 2 } },
    .{ .{ .rank = 7, .file = 6 }, .{ .rank = 5, .file = 5 } },
};

/// A human-friendly duration split into a magnitude and unit string.
const Duration = struct {
    value: f64,
    unit: []const u8,
};

/// Converts raw nanoseconds into the most readable unit (ns, µs, or ms).
fn format_duration(ns: u64) Duration {
    const ns_f: f64 = @floatFromInt(ns);
    if (ns >= 1_000_000_000) return .{ .value = ns_f / 1_000_000_000, .unit = "s" };
    if (ns >= 1_000_000) return .{ .value = ns_f / 1_000_000.0, .unit = "ms" };
    if (ns >= 1_000) return .{ .value = ns_f / 1_000.0, .unit = "µs" };
    return .{ .value = ns_f, .unit = "ns" };
}

/// Returns a monotonic timestamp in nanoseconds.
fn timestamp_ns() u64 {
    const clock = if (@hasField(std.c.CLOCK, "UPTIME_RAW")) .UPTIME_RAW else .MONOTONIC;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Sleeps for the given number of nanoseconds using the C nanosleep syscall.
fn sleep_ns(ns: u64) void {
    const secs = ns / std.time.ns_per_s;
    const rem_ns = ns % std.time.ns_per_s;
    var req = std.c.timespec{
        .sec = @intCast(secs),
        .nsec = @intCast(rem_ns),
    };
    while (true) {
        var rem: std.c.timespec = undefined;
        const rc = std.c.nanosleep(&req, &rem);
        if (rc == 0) return;
        // Interrupted by signal, sleep the remainder.
        req = rem;
    }
}

/// Aggregated statistics for a set of timing samples.
///
///   min / max   — fastest and slowest individual iteration.
///   avg         — arithmetic mean across all samples.
///   p50 / p99   — median and 99th-percentile latency (after sorting).
///   stddev      — standard deviation: measures how spread out the samples are
///                 from the average. A small stddev means consistent timings; a
///                 large one means high variance between iterations.
const Stats = struct {
    min: u64,
    max: u64,
    avg: u64,
    p50: u64,
    p99: u64,
    stddev: u64,
};

/// Sorts the samples in place, then computes min/max/avg/p50/p99/stddev.
/// The sort is required for percentile calculation — the p50 value is just the
/// middle element and p99 is the element at the 99% index.
fn compute_stats(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const avg: u64 = @intCast(sum / samples.len);

    // Variance is the average of squared differences from the mean.
    // stddev = sqrt(variance) brings it back to the same unit as the samples.
    var variance_sum: u128 = 0;
    for (samples) |s| {
        const diff: i128 = @as(i128, s) - @as(i128, avg);
        variance_sum += @intCast(diff * diff);
    }
    const variance: u64 = @intCast(variance_sum / samples.len);
    const stddev: u64 = std.math.sqrt(variance);

    return .{
        .min = samples[0],
        .max = samples[samples.len - 1],
        .avg = avg,
        .p50 = samples[samples.len / 2],
        .p99 = samples[(samples.len * 99) / 100],
        .stddev = stddev,
    };
}

// ── Result output buffer ─────────────────────────────────────────────────────
// Accumulates the full benchmark report so it can be written to both stderr
// and a file in one shot.
const RESULT_BUF_SIZE = 4096;

const ResultWriter = struct {
    buf: [RESULT_BUF_SIZE]u8 = undefined,
    len: usize = 0,

    fn print(self: *ResultWriter, comptime fmt: []const u8, args: anytype) void {
        const slice = self.buf[self.len..];
        const written = std.fmt.bufPrint(slice, fmt, args) catch {
            return;
        };
        self.len += written.len;
    }

    fn contents(self: *const ResultWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

fn write_stat_block(w: *ResultWriter, label: []const u8, stats: Stats) void {
    const min = format_duration(stats.min);
    const avg = format_duration(stats.avg);
    const p50 = format_duration(stats.p50);
    const p99 = format_duration(stats.p99);
    const max = format_duration(stats.max);
    const sd = format_duration(stats.stddev);

    w.print("  {s}\r\n", .{label});
    w.print("    min    {d:>8.1} {s}\r\n", .{ min.value, min.unit });
    w.print("    avg    {d:>8.1} {s}\r\n", .{ avg.value, avg.unit });
    w.print("    p50    {d:>8.1} {s}\r\n", .{ p50.value, p50.unit });
    w.print("    p99    {d:>8.1} {s}\r\n", .{ p99.value, p99.unit });
    w.print("    max    {d:>8.1} {s}\r\n", .{ max.value, max.unit });
    w.print("    stddev {d:>8.1} {s}\r\n", .{ sd.value, sd.unit });
}

/// Queries a macOS sysctl string value by name into the provided buffer.
/// Returns the slice of the buffer that was filled, or null if the call failed.
fn sysctl_string(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    var len: usize = buf.len;
    const rc = std.c.sysctlbyname(name, buf.ptr, &len, null, 0);
    if (rc != 0 or len == 0) return null;
    // sysctl includes a trailing null byte in the returned length.
    const str_len = if (buf[len - 1] == 0) len - 1 else len;
    return buf[0..str_len];
}

/// Queries a macOS sysctl u64 value by name. Returns null if the call failed.
fn sysctl_u64(name: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var len: usize = @sizeOf(u64);
    const rc = std.c.sysctlbyname(name, @ptrCast(&value), &len, null, 0);
    if (rc != 0) return null;
    return value;
}

fn write_system_info(w: *ResultWriter) void {
    var cpu_buf: [256]u8 = undefined;
    const cpu = sysctl_string("machdep.cpu.brand_string", &cpu_buf) orelse "unknown";
    const ram_bytes = sysctl_u64("hw.memsize") orelse 0;
    const ram_gb = @as(f64, @floatFromInt(ram_bytes)) / (1024.0 * 1024.0 * 1024.0);

    w.print("  cpu:   {s}\r\n", .{cpu});
    w.print("  ram:   {d:.0} GB\r\n", .{ram_gb});
}

/// Writes the result buffer to a file at the given path. Silently does nothing
/// on failure — benchmark results are already on screen.
fn write_results_file(path: [*:0]const u8, data: []const u8) void {
    // O_WRONLY | O_CREAT | O_TRUNC
    const O = std.c.O;
    const mode: std.c.mode_t = 0o644;
    const fd = std.c.open(
        path,
        @bitCast(O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }),
        mode,
    );
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, data.ptr, data.len);
}

pub fn main() !void {
    var io = try terminal_io.TerminalIO.init();
    try io.enable_raw_mode();
    defer io.restore_termios();

    var board: chess_board.Board = undefined;
    try board.init(io.window_config);

    // Per-iteration nanosecond timings, filled during the loop and fed to
    // compute_stats afterwards. build = buffer construction, write = terminal
    // I/O, total = build + write for each iteration.
    var build_samples: [ITERATIONS]u64 = undefined;
    var write_samples: [ITERATIONS]u64 = undefined;
    var total_samples: [ITERATIONS]u64 = undefined;

    // Counts how many frames the terminal write syscall accepted successfully.
    // Should equal ITERATIONS if all frames were delivered to the pty buffer.
    var successful_writes: u32 = 0;

    const move_count = moves.len;
    const wall_start = timestamp_ns();

    for (0..ITERATIONS) |i| {
        const move_idx = i % move_count;

        // Reset to starting position at the beginning of each cycle so every
        // set of moves is applied to a valid board. The reset is deliberately
        // outside the timed region (draw captures its own metrics).
        if (move_idx == 0) {
            try board.init(io.window_config);
        }

        const m = moves[move_idx];
        board.move(m[0], m[1]);
        board.flip_perspective();

        try board.draw();

        const metrics = board.frame_metrics.?;
        build_samples[i] = metrics.build_ns;
        write_samples[i] = metrics.write_ns;
        total_samples[i] = metrics.build_ns + metrics.write_ns;

        // Track whether the write syscall succeeded (returned a positive byte count).
        // draw() writes to stdout via TerminalIO.write which returns the result of the
        // underlying write() syscall — positive means bytes were accepted by the pty.
        if (metrics.write_ns > 0) successful_writes += 1;

        // Sleep between frames so the terminal actually renders each one and
        // CPU caches cool down, giving realistic per-frame latency numbers.
        sleep_ns(FRAME_DELAY_NS);
    }

    const wall_elapsed_ns = timestamp_ns() - wall_start;

    // Restore terminal before printing results so they aren't cleared.
    io.restore_termios();

    // Clear the screen so the last rendered board doesn't sit above the results.
    _ = terminal_io.TerminalIO.write(
        terminal_io.EscapeSequences.CLEAR_SCREEN ++ terminal_io.EscapeSequences.SET_CURSOR_TO_HOME,
    );

    const size_kb = board.frame_metrics.?.size_kb;
    const elapsed = format_duration(wall_elapsed_ns);
    const delay_ms = @as(f64, @floatFromInt(FRAME_DELAY_NS)) / 1_000_000.0;

    // Build the full report into a buffer so we can write it to both stderr and a file.
    var results: ResultWriter = .{};

    results.print("=== Benchmark ===\r\n", .{});
    write_system_info(&results);
    results.print("  iters: {d}, {d:.2} KB/frame, {d:.0} ms inter-frame delay\r\n", .{
        ITERATIONS, size_kb, delay_ms,
    });
    results.print("  wrote: {d}/{d} frames delivered to pty\r\n", .{
        successful_writes,
        ITERATIONS,
    });
    results.print("  clock: {d:.1} {s}\r\n", .{ elapsed.value, elapsed.unit });
    results.print("\r\n", .{});

    write_stat_block(&results, "buffer build", compute_stats(&build_samples));
    results.print("\r\n", .{});
    write_stat_block(&results, "terminal write", compute_stats(&write_samples));
    results.print("\r\n", .{});
    write_stat_block(&results, "total (b+w)", compute_stats(&total_samples));
    results.print("\r\n", .{});

    // Print to terminal.
    std.debug.print("{s}", .{results.contents()});

    // Also persist to file for later reference.
    write_results_file("tmp/bench_results.txt", results.contents());
}
