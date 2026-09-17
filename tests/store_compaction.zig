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
    try testing.expectEqual(@as(u64, 3), reopened.shard.index.generation);
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
    try testing.expectEqual(@as(u64, 1), store.shard.index.generation);
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
        try testing.expectEqual(@as(u64, 1), store.shard.index.generation);
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
    try testing.expectEqual(@as(u64, 1), store.shard.index.generation);
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
        try testing.expectEqual(@as(u64, 1), store.shard.index.generation);
        try testing.expectError(error.WriterFailed, store.write(.{ .entries = &.{item(3, 2, "later")} }));
    }
}
