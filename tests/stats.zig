const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/shard.zig");
const item = support.item;
const region = support.header.region;

test "store stats: get_calls counts hits and misses" {
    if (!db.directory.supported) return error.SkipZigTest;

    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });

    var output: [128]u8 = undefined;
    var required: usize = 0;
    _ = try store.get(item(1, 0, "").key, &output);
    _ = try store.get(item(1, 1, "").key, &output);
    _ = try store.getSized(item(1, 0, "").key, &output, &required);

    try testing.expectEqual(@as(u64, 3), stats.get_calls.load(.monotonic));
}

test "store stats: writes track batches, records, and byte totals" {
    if (!db.directory.supported) return error.SkipZigTest;

    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats });
    defer store.deinit();

    _ = try store.write(.{ .entries = &.{ item(1, 0, "abc"), item(1, 1, "defgh") } });

    try testing.expectEqual(@as(u64, 1), stats.writes.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), stats.records_written.load(.monotonic));
    try testing.expectEqual(@as(u64, 8), stats.raw_bytes_written.load(.monotonic));
    try testing.expectEqual(@as(u64, 8), stats.compressed_bytes_written.load(.monotonic));
}

test "store stats: disk reads only move on a real read, not an index-only miss" {
    if (!db.directory.supported) return error.SkipZigTest;

    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });

    try testing.expectEqual(@as(u64, 0), stats.disk_reads.load(.monotonic));

    var output: [128]u8 = undefined;
    try testing.expectEqual(null, try store.get(item(1, 1, "").key, &output));
    try testing.expectEqual(@as(u64, 0), stats.disk_reads.load(.monotonic));

    try testing.expectEqualStrings("saved", (try store.get(item(1, 0, "").key, &output)).?);
    try testing.expectEqual(@as(u64, 2), stats.disk_reads.load(.monotonic));
    try testing.expect(stats.bytes_read.load(.monotonic) > 0);
}

test "store stats: segment_rotations counts forced rotations" {
    if (!db.directory.supported) return error.SkipZigTest;

    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const one_batch_size = try (db.WriteBatch{ .entries = &.{item(1, 0, "saved")} }).size();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{
        .max_segments = 3,
        .max_segment_size = 48 + one_batch_size,
        .batch_buffer_size = 256,
        .stats = &stats,
    });
    defer store.deinit();

    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try testing.expectEqual(@as(u64, 0), stats.segment_rotations.load(.monotonic));

    _ = try store.write(.{ .entries = &.{item(2, 1, "saved")} });
    try testing.expectEqual(@as(u64, 1), stats.segment_rotations.load(.monotonic));
}

test "store stats: compaction counts move on success" {
    if (!db.directory.supported) return error.SkipZigTest;

    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{
        .max_segment_size = 256,
        .batch_buffer_size = 256,
        .stats = &stats,
    });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "old")} });
    _ = try store.write(.{ .entries = &.{item(2, 0, "saved")} });

    const result = try store.compact();

    try testing.expectEqual(@as(u64, 1), stats.compactions.load(.monotonic));
    try testing.expectEqual(result.source_bytes, stats.compaction_input_bytes.load(.monotonic));
    try testing.expectEqual(result.output_bytes, stats.compaction_output_bytes.load(.monotonic));
}

test "store stats: fsync_count reflects sync vs buffered durability" {
    if (!db.directory.supported) return error.SkipZigTest;

    var sync_stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var synced_store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &sync_stats });
    defer synced_store.deinit();
    _ = try synced_store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try testing.expectEqual(@as(u64, 1), sync_stats.fsync_count.load(.monotonic));

    var buffered_stats: db.Stats = .{};
    var other = testing.tmpDir(.{});
    defer other.cleanup();
    var buffered_store = try db.Store.create(testing.allocator, io, other.dir, region, .{
        .durability = .buffered,
        .stats = &buffered_stats,
    });
    defer buffered_store.deinit();
    _ = try buffered_store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try testing.expectEqual(@as(u64, 0), buffered_stats.fsync_count.load(.monotonic));

    try buffered_store.flush();
    try testing.expectEqual(@as(u64, 1), buffered_stats.fsync_count.load(.monotonic));
}
