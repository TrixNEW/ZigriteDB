const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const support = @import("support/shard.zig");
const item = support.item;
const region = support.header.region;

test "store installs compacted generations and reclaims old files" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 256, .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "old")} });
    _ = try store.write(.{ .entries = &.{item(2, 0, "saved")} });
    const unrelated = try tmp.dir.createFile(io, "0000000000000001-0000000000000063.segment", .{ .exclusive = true });
    unrelated.close(io);
    const result = try store.compact();
    try testing.expectEqual(@as(u64, 2), result.generation);
    try testing.expectEqual(@as(usize, 1), result.segment_count);
    try testing.expect(result.output_bytes < result.source_bytes);
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000063.segment", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "0000000000000001-0000000000000001.segment", .{}));
    try testing.expectEqual(@as(usize, 2), result.cleanup.removed_segments);
    try testing.expect(result.cleanup.synced and result.cleanup.failure == null);
    try testing.expectEqual(error.InvalidGeneration, (try store.reclaim(2, &.{1})).failure.?);
    try testing.expectEqual(@as(usize, 0), (try store.reclaim(1, &.{ 1, 2 })).retained_segments);
    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(item(2, 0, "").key, &value)).?);
    _ = try store.write(.{ .entries = &.{item(3, 0, null)} });
    try testing.expectEqual(@as(u64, 3), (try store.compact()).generation);
    try testing.expectEqual(null, try store.get(item(3, 0, "").key, &value));
    try store.close();
    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    try testing.expectEqual(@as(u64, 3), reopened.shard.generation.index.generation);
    try testing.expectError(error.BatchOrder, reopened.write(.{ .entries = &.{item(3, 1, "late")} }));
    _ = try reopened.write(.{ .entries = &.{item(4, 1, "new")} });
    try reopened.close();
    try testing.expectError(error.Closed, reopened.compact());
}

test "failed compaction publication keeps the old view and stops writes" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    const temporary = try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true });
    temporary.close(io);
    try testing.expectError(error.PathAlreadyExists, store.compact());
    try testing.expectEqual(@as(u64, 1), store.shard.generation.index.generation);
    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(item(1, 0, "").key, &value)).?);
    try testing.expectError(error.WriterFailed, store.write(.{ .entries = &.{item(2, 0, "later")} }));
    try testing.expectError(error.WriterFailed, store.close());
    var scratch: [512]u8 = undefined;
    var orphans: [4]db.inspection.Orphan = undefined;
    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(@as(?u64, 1), report.generation);
    try testing.expect(report.temporary_manifest);
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000001.segment", .{});
}

test "compaction never overwrites an existing generation" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    const existing = try tmp.dir.createFile(io, "0000000000000002-0000000000000001.segment", .{ .exclusive = true });
    existing.close(io);
    try testing.expectError(error.PathAlreadyExists, store.compact());
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try store.close();
}

test "compaction allocation failures preserve the current store" {
    if (!db.directory.supported) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, compactWithAllocator, .{});
}

fn compactWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(allocator, io, tmp.dir, region, .{ .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    _ = store.compact() catch |err| {
        var value: [128]u8 = undefined;
        try testing.expectEqualStrings("saved", (try store.get(item(1, 0, "").key, &value)).?);
        try testing.expectEqual(@as(u64, 1), store.shard.generation.index.generation);
        return err;
    };
    try store.close();
}

test "cleanup reports retained paths without interrupting the store" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.compact();
    const name = "0000000000000001-0000000000000009.segment";
    try tmp.dir.createDir(io, name, .default_dir);
    const result = try store.reclaim(1, &.{9});
    try testing.expectEqual(@as(usize, 1), result.retained_segments);
    try testing.expect(result.failure != null);
    _ = try tmp.dir.statFile(io, name, .{});
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try store.close();
}

test "compaction stops writes after source corruption" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "old")} });
    _ = try store.write(.{ .entries = &.{item(2, 0, "saved")} });
    var byte: [1]u8 = undefined;
    const offset = db.segment.encoded_len + db.record.encoded_len + db.Key.encoded_len;
    try store.devices[0].readExact(&byte, offset);
    byte[0] ^= 1;
    try store.devices[0].writeAll(&byte, offset);
    try testing.expectError(error.ChecksumMismatch, store.compact());
    try testing.expectEqual(@as(u64, 1), store.shard.generation.index.generation);
    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(item(2, 0, "").key, &value)).?);
    try testing.expectError(error.WriterFailed, store.write(.{ .entries = &.{item(3, 1, "later")} }));
    try testing.expectError(error.WriterFailed, store.reclaim(1, &.{1}));
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000001.segment", .{});
}

test "compaction stops writes after source truncation" {
    if (!db.directory.supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |partial| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
        defer store.deinit();
        const first = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
        _ = try store.write(.{ .entries = &.{item(2, 1, "lost")} });
        try store.devices[0].handle.setLength(io, first.end + @as(u64, if (partial) 1 else 0));
        try testing.expectError(if (partial) error.NeedsRecovery else error.FileChanged, store.compact());
        try testing.expectEqual(@as(u64, 1), store.shard.generation.index.generation);
        try testing.expectError(error.WriterFailed, store.write(.{ .entries = &.{item(3, 2, "later")} }));
    }
}

fn readLoop(store: *db.Store, key: db.Key, iterations: usize, failure: *?anyerror) void {
    var output: [128]u8 = undefined;
    for (0..iterations) |_| {
        _ = store.get(key, &output) catch |err| {
            failure.* = err;
            return;
        };
    }
}

test "reads during compaction stay safe and see a valid value" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 4096, .batch_buffer_size = 512 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });

    var failure: ?anyerror = null;
    const key = item(1, 0, "").key;
    const reader = try std.Thread.spawn(.{}, readLoop, .{ &store, key, @as(usize, 3000), &failure });

    var batch: u64 = 2;
    for (0..20) |_| {
        _ = try store.write(.{ .entries = &.{item(batch, 1, "saved")} });
        batch += 1;
        _ = try store.compact();
    }
    reader.join();

    try testing.expectEqual(null, failure);
}

/// Regression test: `required` should match the status even when a write races it.
fn getSizedLoop(store: *db.Store, key: db.Key, iterations: usize, failure: *?[]const u8) void {
    var small: [16]u8 = undefined;
    for (0..iterations) |_| {
        var required: usize = 0;
        if (store.getSized(key, &small, &required)) |value| {
            if (value != null and required != 16) failure.* = "size mismatch on success";
        } else |err| {
            if (err != error.BufferTooSmall or required != 512) failure.* = "size mismatch on BufferTooSmall";
        }
    }
}

test "getSized required always matches the size that produced it" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 1 << 20, .batch_buffer_size = 4096 });
    defer store.deinit();
    var small_value: [16]u8 = undefined;
    @memset(&small_value, 'a');
    _ = try store.write(.{ .entries = &.{item(1, 0, &small_value)} });

    var failure: ?[]const u8 = null;
    const key = item(1, 0, "").key;
    const reader = try std.Thread.spawn(.{}, getSizedLoop, .{ &store, key, @as(usize, 3000), &failure });

    var large_value: [512]u8 = undefined;
    @memset(&large_value, 'b');
    var batch: u64 = 2;
    for (0..1500) |i| {
        const value: []const u8 = if (i % 2 == 0) &large_value else &small_value;
        _ = try store.write(.{ .entries = &.{item(batch, 0, value)} });
        batch += 1;
    }
    reader.join();

    try testing.expectEqual(null, failure);
}

test "getMany verifies each segment header once instead of once per key" {
    if (!db.directory.supported) return error.SkipZigTest;
    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const two_entry_size = try (db.WriteBatch{ .entries = &.{ item(1, 0, "aa"), item(1, 1, "bb") } }).size();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{
        .max_segments = 3,
        .max_segment_size = 48 + two_entry_size,
        .batch_buffer_size = 256,
        .stats = &stats,
    });
    defer store.deinit();

    _ = try store.write(.{ .entries = &.{ item(1, 0, "aa"), item(1, 1, "bb") } }); // segment 1
    _ = try store.write(.{ .entries = &.{ item(2, 2, "cc"), item(2, 3, "dd") } }); // rotates to segment 2

    var out: [4][16]u8 = undefined;
    const requests = [_]db.ReadRequest{
        .{ .key = item(1, 0, "").key, .output = &out[0] },
        .{ .key = item(1, 1, "").key, .output = &out[1] },
        .{ .key = item(1, 2, "").key, .output = &out[2] },
        .{ .key = item(1, 3, "").key, .output = &out[3] },
    };
    var results: [4]db.ReadResult = undefined;

    stats.reset();
    try store.getMany(&requests, &results);
    for (results) |r| try testing.expectEqual(db.ReadStatus.ok, r.status);
    // 2 header checks + 4 records
    try testing.expectEqual(@as(u64, 6), stats.disk_reads.load(.monotonic));

    stats.reset();
    for (requests) |request| _ = try store.get(request.key, request.output);
    // independent gets re-check the header every time: 4 headers + 4 records
    try testing.expectEqual(@as(u64, 8), stats.disk_reads.load(.monotonic));
}

fn getManyLoop(store: *db.Store, requests: []const db.ReadRequest, results: []db.ReadResult, failure: *?anyerror) void {
    for (0..1000) |_| {
        store.getMany(requests, results) catch |err| {
            failure.* = err;
            return;
        };
        for (results) |r| {
            if (r.status != .ok) {
                failure.* = error.TestUnexpectedResult;
                return;
            }
        }
    }
}

test "getMany during compaction stays safe" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 4096, .batch_buffer_size = 512 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{ item(1, 0, "aa"), item(1, 1, "bb") } });

    var out: [2][16]u8 = undefined;
    const requests = [_]db.ReadRequest{
        .{ .key = item(1, 0, "").key, .output = &out[0] },
        .{ .key = item(1, 1, "").key, .output = &out[1] },
    };
    var results: [2]db.ReadResult = undefined;
    var failure: ?anyerror = null;
    const reader = try std.Thread.spawn(.{}, getManyLoop, .{ &store, &requests, &results, &failure });

    var batch: u64 = 2;
    for (0..20) |_| {
        _ = try store.write(.{ .entries = &.{item(batch, 2, "saved")} });
        batch += 1;
        _ = try store.compact();
    }
    reader.join();

    try testing.expectEqual(null, failure);
}
