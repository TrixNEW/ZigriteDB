const std = @import("std");

/// Shared atomic counters for one World/Handle; a null pointer disables instrumentation.
pub const Stats = struct {
    get_calls: std.atomic.Value(u64) = .init(0),
    writes: std.atomic.Value(u64) = .init(0),
    records_written: std.atomic.Value(u64) = .init(0),
    raw_bytes_written: std.atomic.Value(u64) = .init(0),
    compressed_bytes_written: std.atomic.Value(u64) = .init(0),
    disk_reads: std.atomic.Value(u64) = .init(0),
    bytes_read: std.atomic.Value(u64) = .init(0),
    fsync_count: std.atomic.Value(u64) = .init(0),
    fsync_duration_ns: std.atomic.Value(u64) = .init(0),
    segment_rotations: std.atomic.Value(u64) = .init(0),
    compactions: std.atomic.Value(u64) = .init(0),
    compaction_input_bytes: std.atomic.Value(u64) = .init(0),
    compaction_output_bytes: std.atomic.Value(u64) = .init(0),
    compaction_duration_ns: std.atomic.Value(u64) = .init(0),
    recovery_attempts: std.atomic.Value(u64) = .init(0),
    recovery_errors: std.atomic.Value(u64) = .init(0),

    /// Not safe against concurrent operations; call only when the handle is quiescent.
    pub fn reset(self: *Stats) void {
        inline for (std.meta.fields(Stats)) |field| {
            @field(self, field.name).store(0, .monotonic);
        }
    }
};

test "reset zeroes every counter even while a concurrent op is mid-flight" {
    var stats: Stats = .{};
    stats.get_calls.store(3, .monotonic);
    stats.writes.store(7, .monotonic);
    stats.fsync_duration_ns.store(1234, .monotonic);

    stats.reset();

    inline for (std.meta.fields(Stats)) |field| {
        try std.testing.expectEqual(@as(u64, 0), @field(stats, field.name).load(.monotonic));
    }
}
