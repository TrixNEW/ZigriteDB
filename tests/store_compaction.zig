const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const support = @import("support/shard.zig");
const item = support.item;
const region = support.header.region;

test "store installs compacted generations and keeps old files" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 256, .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "old")} });
    _ = try store.write(.{ .entries = &.{item(2, 0, "saved")} });
    const result = try store.compact();
    try testing.expectEqual(@as(u64, 2), result.generation);
    try testing.expectEqual(@as(usize, 1), result.segment_count);
    try testing.expect(result.output_bytes < result.source_bytes);
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000001.segment", .{});
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
