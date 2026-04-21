//! Benchmark for the chess engine's hot paths: applying a move (through the rule engine) and
//! building the renderer's byte-sequence buffer. Replays The Immortal Game (Anderssen vs
//! Kieseritzky, 1851, 45 half-moves, no castling / en-passant / promotion) on a loop and sprinkles
//! illegal-move attempts every Nth iteration so we capture the rule engine's rejection path
//! separately.
//!
//! Timing uses `std.Io.Clock` on the `.awake` monotonic clock (Zig 0.16.0 replaced
//! `std.time.Timer`). Output goes to stderr via `std.debug.print` and to
//! `tmp/bench/bench_results.txt` via `std.Io.Dir.cwd().writeFile`. No libc clock, no
//! `std.c.clock_gettime`.

const std = @import("std");
const builtin = @import("builtin");

const board_renderer = @import("board_renderer");
const game_mod = @import("game");
const rules_engine = @import("rules");
const shared = @import("shared.zig");

const Clock = std.Io.Clock;
const Threaded = std.Io.Threaded;
const Io = std.Io;

const Game = game_mod.Game;
const BoardRenderer = board_renderer.BoardRenderer;
const Move = shared.Move;
const Position = shared.Position;

// ── Configuration ─────────────────────────────────────────────────────────────

/// Total loop iterations. One iteration is either a legal move+render pair or an illegal-move
/// rejection attempt, decided by `ILLEGAL_MOVE_EVERY_N`.
const ITERATIONS: usize = 10_000;

/// Every Nth iteration is an illegal-move rejection sample instead of a legal move. With
/// `ITERATIONS = 10_000` and `N = 10` the split is 9000 legal / 1000 illegal.
const ILLEGAL_MOVE_EVERY_N: usize = 10;

/// Length of one full replay of The Immortal Game (45 half-moves; see `IMMORTAL_GAME` below).
const MOVE_CYCLE_LEN: usize = IMMORTAL_GAME.len;

/// Size of the stack buffer that accumulates the full result report. Four stat blocks
/// (apply / reject / cycle / renderer) at ~210 bytes each ≈ 850 bytes, plus the header /
/// system-info block (~500 bytes) land at ~1.5 KB peak. 8 KB leaves generous headroom so a
/// future metric doesn't silently truncate via `bufPrint`'s catch-and-return.
const RESULT_BUFFER_SIZE: usize = 8 * 1024;

/// On-disk path for the persisted report, relative to cwd.
const RESULT_FILE_PATH = "tmp/bench/bench_results.txt";

/// Parent directory of `RESULT_FILE_PATH` — created on demand.
const RESULT_FILE_DIR = "tmp/bench";

/// Synthetic terminal size that triggers the renderer's largest cell dimensions (11x5 per cell),
/// which is the worst-case buffer size (~12 KB) and therefore the measurement we actually want.
/// The bench never touches the real tty.
const BENCH_WINDOW_COLS: u16 = 94;
const BENCH_WINDOW_ROWS: u16 = 46;

// ── Move tables ───────────────────────────────────────────────────────────────

// The Immortal Game, Anderssen vs Kieseritzky, London, 1851. 23 full moves = 45 half-moves.
// Source: https://en.wikipedia.org/wiki/Immortal_Game.
//
// Board coordinates: `rank` is 0-indexed from white's back rank (so rank_idx 0 == chess rank 1),
// `file` is 0-indexed a..h. e2-e4 therefore reads as .{ .rank = 1, .file = 4 } → .{ 3, 4 }.
//
// This sequence is free of castling, en-passant, and promotion — all of which the current rule
// engine either doesn't model (`CastlingRights` is an empty placeholder, `en_passant_square` stays
// null) or models partially. Anderssen forfeits castling rights on move 4 (Kf1); Kieseritzky
// never castles.
const IMMORTAL_GAME = [_]Move{
    // 1. e4 e5
    .{ .from = .{ .rank = 1, .file = 4 }, .to = .{ .rank = 3, .file = 4 } },
    .{ .from = .{ .rank = 6, .file = 4 }, .to = .{ .rank = 4, .file = 4 } },
    // 2. f4 exf4
    .{ .from = .{ .rank = 1, .file = 5 }, .to = .{ .rank = 3, .file = 5 } },
    .{ .from = .{ .rank = 4, .file = 4 }, .to = .{ .rank = 3, .file = 5 } },
    // 3. Bc4 Qh4+
    .{ .from = .{ .rank = 0, .file = 5 }, .to = .{ .rank = 3, .file = 2 } },
    .{ .from = .{ .rank = 7, .file = 3 }, .to = .{ .rank = 3, .file = 7 } },
    // 4. Kf1 b5
    .{ .from = .{ .rank = 0, .file = 4 }, .to = .{ .rank = 0, .file = 5 } },
    .{ .from = .{ .rank = 6, .file = 1 }, .to = .{ .rank = 4, .file = 1 } },
    // 5. Bxb5 Nf6
    .{ .from = .{ .rank = 3, .file = 2 }, .to = .{ .rank = 4, .file = 1 } },
    .{ .from = .{ .rank = 7, .file = 6 }, .to = .{ .rank = 5, .file = 5 } },
    // 6. Nf3 Qh6
    .{ .from = .{ .rank = 0, .file = 6 }, .to = .{ .rank = 2, .file = 5 } },
    .{ .from = .{ .rank = 3, .file = 7 }, .to = .{ .rank = 5, .file = 7 } },
    // 7. d3 Nh5
    .{ .from = .{ .rank = 1, .file = 3 }, .to = .{ .rank = 2, .file = 3 } },
    .{ .from = .{ .rank = 5, .file = 5 }, .to = .{ .rank = 4, .file = 7 } },
    // 8. Nh4 Qg5
    .{ .from = .{ .rank = 2, .file = 5 }, .to = .{ .rank = 3, .file = 7 } },
    .{ .from = .{ .rank = 5, .file = 7 }, .to = .{ .rank = 4, .file = 6 } },
    // 9. Nf5 c6
    .{ .from = .{ .rank = 3, .file = 7 }, .to = .{ .rank = 4, .file = 5 } },
    .{ .from = .{ .rank = 6, .file = 2 }, .to = .{ .rank = 5, .file = 2 } },
    // 10. g4 Nf6
    .{ .from = .{ .rank = 1, .file = 6 }, .to = .{ .rank = 3, .file = 6 } },
    .{ .from = .{ .rank = 4, .file = 7 }, .to = .{ .rank = 5, .file = 5 } },
    // 11. Rg1 cxb5
    .{ .from = .{ .rank = 0, .file = 7 }, .to = .{ .rank = 0, .file = 6 } },
    .{ .from = .{ .rank = 5, .file = 2 }, .to = .{ .rank = 4, .file = 1 } },
    // 12. h4 Qg6
    .{ .from = .{ .rank = 1, .file = 7 }, .to = .{ .rank = 3, .file = 7 } },
    .{ .from = .{ .rank = 4, .file = 6 }, .to = .{ .rank = 5, .file = 6 } },
    // 13. h5 Qg5
    .{ .from = .{ .rank = 3, .file = 7 }, .to = .{ .rank = 4, .file = 7 } },
    .{ .from = .{ .rank = 5, .file = 6 }, .to = .{ .rank = 4, .file = 6 } },
    // 14. Qf3 Ng8
    .{ .from = .{ .rank = 0, .file = 3 }, .to = .{ .rank = 2, .file = 5 } },
    .{ .from = .{ .rank = 5, .file = 5 }, .to = .{ .rank = 7, .file = 6 } },
    // 15. Bxf4 Qf6
    .{ .from = .{ .rank = 0, .file = 2 }, .to = .{ .rank = 3, .file = 5 } },
    .{ .from = .{ .rank = 4, .file = 6 }, .to = .{ .rank = 5, .file = 5 } },
    // 16. Nc3 Bc5
    .{ .from = .{ .rank = 0, .file = 1 }, .to = .{ .rank = 2, .file = 2 } },
    .{ .from = .{ .rank = 7, .file = 5 }, .to = .{ .rank = 4, .file = 2 } },
    // 17. Nd5 Qxb2
    .{ .from = .{ .rank = 2, .file = 2 }, .to = .{ .rank = 4, .file = 3 } },
    .{ .from = .{ .rank = 5, .file = 5 }, .to = .{ .rank = 1, .file = 1 } },
    // 18. Bd6 Bxg1
    .{ .from = .{ .rank = 3, .file = 5 }, .to = .{ .rank = 5, .file = 3 } },
    .{ .from = .{ .rank = 4, .file = 2 }, .to = .{ .rank = 0, .file = 6 } },
    // 19. e5 Qxa1+
    .{ .from = .{ .rank = 3, .file = 4 }, .to = .{ .rank = 4, .file = 4 } },
    .{ .from = .{ .rank = 1, .file = 1 }, .to = .{ .rank = 0, .file = 0 } },
    // 20. Ke2 Na6
    .{ .from = .{ .rank = 0, .file = 5 }, .to = .{ .rank = 1, .file = 4 } },
    .{ .from = .{ .rank = 7, .file = 1 }, .to = .{ .rank = 5, .file = 0 } },
    // 21. Nxg7+ Kd8
    .{ .from = .{ .rank = 4, .file = 5 }, .to = .{ .rank = 6, .file = 6 } },
    .{ .from = .{ .rank = 7, .file = 4 }, .to = .{ .rank = 7, .file = 3 } },
    // 22. Qf6+ Nxf6
    .{ .from = .{ .rank = 2, .file = 5 }, .to = .{ .rank = 5, .file = 5 } },
    .{ .from = .{ .rank = 7, .file = 6 }, .to = .{ .rank = 5, .file = 5 } },
    // 23. Be7#
    .{ .from = .{ .rank = 5, .file = 3 }, .to = .{ .rank = 6, .file = 4 } },
};

// Illegal moves used to exercise the rule engine's rejection path. Each originates on a square
// that is never occupied at any point during The Immortal Game (a4, d4, a5), so `preview_move`'s
// `piece == .empty` short-circuit fires deterministically regardless of the current position
// within the replay.
const ILLEGAL_MOVES = [_]Move{
    .{ .from = .{ .rank = 3, .file = 0 }, .to = .{ .rank = 4, .file = 0 } }, // a4→a5, empty from
    .{ .from = .{ .rank = 3, .file = 3 }, .to = .{ .rank = 4, .file = 3 } }, // d4→d5, empty from
    .{ .from = .{ .rank = 4, .file = 0 }, .to = .{ .rank = 5, .file = 0 } }, // a5→a6, empty from
};

// ── Stats ─────────────────────────────────────────────────────────────────────

/// Aggregate summary over a set of nanosecond samples. Sorts the samples in place during
/// `compute_stats`, so callers must not rely on the input order post-call.
///
///   min / max — fastest and slowest individual iteration.
///   avg       — arithmetic mean.
///   p50 / p99 — median and 99th-percentile.
///   stddev    — spread around the mean.
const Stats = struct {
    min: u64,
    max: u64,
    avg: u64,
    p50: u64,
    p99: u64,
    stddev: u64,
};

/// Sorts the samples in place, then computes min/max/avg/p50/p99/stddev. The sort is required
/// for the percentile calculation.
fn compute_stats(samples: []u64) Stats {
    std.debug.assert(samples.len > 0);
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    var sum: u128 = 0;
    for (samples) |s| {
        sum += s;
    }
    const avg: u64 = @intCast(sum / samples.len);

    // Variance = average of squared differences from the mean; stddev = sqrt(variance).
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

/// A human-friendly duration split into a magnitude and unit string.
const Duration = struct {
    value: f64,
    unit: []const u8,
};

/// Converts raw nanoseconds into the most readable unit (ns, us, ms, s).
///
/// Units are kept 2-byte ASCII (including " s" for seconds) so right-aligned output in the stat
/// blocks stays byte-for-byte consistent: a multi-byte "µs" would display as 2 chars but measure
/// as 3 bytes, making `{s:>N}` right-align one char short on µs rows versus ns/ms rows.
fn format_duration(ns: u64) Duration {
    const ns_f: f64 = @floatFromInt(ns);
    if (ns >= std.time.ns_per_s) {
        return .{ .value = ns_f / @as(f64, @floatFromInt(std.time.ns_per_s)), .unit = " s" };
    }
    if (ns >= std.time.ns_per_ms) {
        return .{ .value = ns_f / @as(f64, @floatFromInt(std.time.ns_per_ms)), .unit = "ms" };
    }
    if (ns >= std.time.ns_per_us) {
        return .{ .value = ns_f / @as(f64, @floatFromInt(std.time.ns_per_us)), .unit = "us" };
    }
    return .{ .value = ns_f, .unit = "ns" };
}

// ── Result buffer ─────────────────────────────────────────────────────────────

/// Accumulates the full benchmark report in a fixed-size stack buffer so we can hand the same
/// bytes to both stderr and the results file with zero heap allocation.
const ResultWriter = struct {
    buf: [RESULT_BUFFER_SIZE]u8 = undefined,
    len: usize = 0,

    fn print(self: *ResultWriter, comptime fmt: []const u8, args: anytype) void {
        const slice = self.buf[self.len..];
        const written = std.fmt.bufPrint(slice, fmt, args) catch {
            // The report exceeded RESULT_BUFFER_SIZE. Leave the partial content and bail; the
            // stderr output still reflects what fit.
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

    w.print("  {s}\n", .{label});
    w.print("    min    {d:>8.1} {s}\n", .{ min.value, min.unit });
    w.print("    avg    {d:>8.1} {s}\n", .{ avg.value, avg.unit });
    w.print("    p50    {d:>8.1} {s}\n", .{ p50.value, p50.unit });
    w.print("    p99    {d:>8.1} {s}\n", .{ p99.value, p99.unit });
    w.print("    max    {d:>8.1} {s}\n", .{ max.value, max.unit });
    w.print("    stddev {d:>8.1} {s}\n", .{ sd.value, sd.unit });
}

fn write_system_info(w: *ResultWriter) void {
    w.print("  os:      {s}\n", .{@tagName(builtin.os.tag)});
    w.print("  arch:    {s}\n", .{@tagName(builtin.cpu.arch)});
    w.print("  mode:    {s}\n", .{@tagName(builtin.mode)});
}

// ── Timing helpers ────────────────────────────────────────────────────────────

/// Reads the monotonic `.awake` clock (CLOCK_MONOTONIC on Linux, CLOCK_UPTIME_RAW on macOS) via
/// `std.Io.Clock.Timestamp.now`. Returns the timestamp; callers use `duration_ns_between` to
/// compute elapsed nanoseconds.
inline fn timestamp_now(io: Io) Clock.Timestamp {
    return Clock.Timestamp.now(io, .awake);
}

/// Nanoseconds elapsed from `t0` to `t1`. Expects `t1 >= t0` on the same monotonic clock; the
/// `.awake` clock guarantees this by the Zig 0.16.0 spec.
inline fn duration_ns_between(t0: Clock.Timestamp, t1: Clock.Timestamp) u64 {
    const ns_i96: i96 = t0.durationTo(t1).raw.toNanoseconds();
    // Monotonic clock plus `t1 >= t0` means the delta is non-negative and fits in u64 for any
    // practical benchmark length.
    std.debug.assert(ns_i96 >= 0);
    return @intCast(ns_i96);
}

// ── File output ───────────────────────────────────────────────────────────────

/// Writes `data` to `RESULT_FILE_PATH`, creating the parent directory if needed. Uses
/// `std.Io.Dir` exclusively — no libc, no `std.c.open/write`.
fn write_results_file(io: Io, data: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, RESULT_FILE_DIR);
    try cwd.writeFile(io, .{ .sub_path = RESULT_FILE_PATH, .data = data });
}

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main() void {
    // Single-threaded Io instance for the file-write path and clock reads. `init_single_threaded`
    // pre-initialises everything at comptime, including an allocator that would fail on any
    // concurrent call — fine here because the bench is fully synchronous.
    var threaded: Threaded = Threaded.init_single_threaded;
    const io = threaded.io();

    var game: Game = undefined;
    game.init(.white);

    // Construct a synthetic terminal size large enough to pick the renderer's largest cell
    // dimensions (11x5). This is where the worst-case ~12 KB frame buffer lives, matching the
    // shape the real game will eventually produce.
    const ws: std.posix.winsize = .{
        .col = BENCH_WINDOW_COLS,
        .row = BENCH_WINDOW_ROWS,
        .xpixel = 0,
        .ypixel = 0,
    };
    var renderer: BoardRenderer = undefined;
    renderer.init(ws);

    // Per-iteration samples. `reject_samples` sized to the illegal-move upper bound.
    // `cycle_samples` holds one entry per completed 45-move replay (`ITERATIONS / MOVE_CYCLE_LEN
    // + 1` slots; unused tail stays undefined).
    var apply_samples: [ITERATIONS]u64 = undefined;
    var render_samples: [ITERATIONS]u64 = undefined;
    var reject_samples: [ITERATIONS / ILLEGAL_MOVE_EVERY_N]u64 = undefined;
    var cycle_samples: [ITERATIONS / MOVE_CYCLE_LEN + 1]u64 = undefined;

    var legal_count: usize = 0;
    var reject_count: usize = 0;
    var cycle_count: usize = 0;

    // Cycle accumulator — rolled into `cycle_samples` on the last half-move of each replay.
    // Illegal-move rejection time is deliberately excluded so the full-game stat is independent
    // of `ILLEGAL_MOVE_EVERY_N`.
    var cycle_accum: u64 = 0;

    const wall_start = timestamp_now(io);

    for (0..ITERATIONS) |i| {
        if (i % ILLEGAL_MOVE_EVERY_N == 0) {
            const mv = ILLEGAL_MOVES[reject_count % ILLEGAL_MOVES.len];

            const t0 = timestamp_now(io);
            const legal = if (rules_engine.preview_move(&game.board, game.turn, mv, game.en_passant_square, game.castling_rights)) |_| true else |_| false;
            const t1 = timestamp_now(io);

            // Sanity: the chosen illegal moves originate on always-empty squares, so the rule
            // engine must reject. If this fires, the illegal table or the game state invariant
            // is wrong.
            std.debug.assert(!legal);
            reject_samples[reject_count] = duration_ns_between(t0, t1);
            reject_count += 1;
            continue;
        }

        // Reset at every cycle boundary so every replay starts from the real starting position.
        // Reset runs outside the timed region.
        const cycle_idx = legal_count % MOVE_CYCLE_LEN;
        if (cycle_idx == 0) {
            game.init(.white);
        }
        const mv = IMMORTAL_GAME[cycle_idx];

        const a0 = timestamp_now(io);
        game.play_move(mv) catch {
            std.debug.print(
                "bench: legal move rejected at cycle_idx={d} (iter={d}); aborting\n",
                .{ cycle_idx, i },
            );
            return;
        };
        const a1 = timestamp_now(io);
        const apply_ns = duration_ns_between(a0, a1);
        apply_samples[legal_count] = apply_ns;

        const r0 = timestamp_now(io);
        const buf = renderer.draw(&game);
        const r1 = timestamp_now(io);
        const render_ns = duration_ns_between(r0, r1);
        render_samples[legal_count] = render_ns;
        std.mem.doNotOptimizeAway(buf.len);

        cycle_accum += apply_ns + render_ns;
        if (cycle_idx == MOVE_CYCLE_LEN - 1) {
            cycle_samples[cycle_count] = cycle_accum;
            cycle_count += 1;
            cycle_accum = 0;
        }

        legal_count += 1;
    }

    const wall_end = timestamp_now(io);
    const wall_ns = duration_ns_between(wall_start, wall_end);

    // Cross-check the iteration accounting — catches off-by-ones in the illegal cadence logic
    // without relying on the tests (there are no bench tests).
    std.debug.assert(legal_count + reject_count == ITERATIONS);

    // Build the report.
    var results: ResultWriter = .{};
    results.print("=== Benchmark ===\n", .{});
    write_system_info(&results);
    results.print("  iters:   {d} total ({d} legal, {d} illegal)\n", .{
        ITERATIONS,
        legal_count,
        reject_count,
    });
    results.print("  cycle:   Immortal Game ({d} half-moves, resets at cycle boundary)\n", .{
        MOVE_CYCLE_LEN,
    });
    const wall = format_duration(wall_ns);
    results.print("  clock:   {d:.1} {s} wall\n", .{ wall.value, wall.unit });
    results.print("  cycles:  {d} full {d}-move replays completed\n", .{
        cycle_count,
        MOVE_CYCLE_LEN,
    });
    results.print("\n", .{});

    results.print("── rule engine (filter_self_check, copy-per-candidate) ───────\n", .{});
    write_stat_block(&results, "move apply (play_move, legal)", compute_stats(apply_samples[0..legal_count]));
    results.print("\n", .{});
    write_stat_block(&results, "move reject (preview_move, illegal)", compute_stats(reject_samples[0..reject_count]));
    if (cycle_count > 0) {
        results.print("\n", .{});
        write_stat_block(&results, "full game cycle (45 moves, apply+render)", compute_stats(cycle_samples[0..cycle_count]));
    }

    results.print("\n", .{});

    // Renderer is drawn after every legal move. Per-move samples, not a one-shot measurement.
    results.print("── renderer (drawn after every legal move) ───────────────────\n", .{});
    write_stat_block(&results, "renderer.draw", compute_stats(render_samples[0..legal_count]));

    // Emit to stderr.
    std.debug.print("{s}", .{results.contents()});

    // Persist. Best-effort: if the write fails, the stderr report is still available.
    write_results_file(io, results.contents()) catch |err| {
        std.debug.print(
            "bench: failed to write {s}: {t}\n",
            .{ RESULT_FILE_PATH, err },
        );
    };
}
