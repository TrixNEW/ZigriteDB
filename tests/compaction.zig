const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;
const region = @import("support/shard.zig").header.region;

fn populate(dir: std.Io.Dir) !void {
    var store = try db.Store.create(testing.allocator, io, dir, region, .{ .max_segment_size = 400, .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{ item(1, 0, "old"), item(1, 1, "keep") } });
    _ = try store.write(.{ .entries = &.{ item(2, 0, "new"), item(2, 0, "newer") } });
    _ = try store.write(.{ .entries = &.{item(3, 0, null)} });
    try store.close();
}

test "compaction removes obsolete records and preserves live values" {
    if (!db.directory.supported) return error.SkipZigTest;
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    try populate(source.dir);
    const name = "0000000000000001-0000000000000001.segment";
    const before = try source.dir.statFile(io, name, .{});
    const result = try db.compactTo(testing.allocator, io, source.dir, destination.dir, .{});
    try testing.expect(result.reclaimed_bytes > 0);
    try testing.expectEqual(@as(u64, 2), result.committed_batches);
    try testing.expectEqual(@as(u64, 3), result.last_batch_id);
    try testing.expectEqual(before.size, (try source.dir.statFile(io, name, .{})).size);
    try testing.expect((try destination.dir.statFile(io, name, .{})).size < before.size);

    var store = try db.Store.open(testing.allocator, io, destination.dir, .{});
    defer store.deinit();
    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("keep", (try store.get(item(1, 1, "").key, &value)).?);
    try testing.expectEqual(null, try store.get(item(1, 0, "").key, &value));
    try testing.expectError(error.BatchOrder, store.write(.{ .entries = &.{item(3, 2, "late")} }));
    _ = try store.write(.{ .entries = &.{item(4, 1, null)} });
    try store.close();

    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    const again = try db.compactTo(testing.allocator, io, destination.dir, empty.dir, .{});
    try testing.expectEqual(@as(u64, 4), again.last_batch_id);
    var reopened = try db.Store.open(testing.allocator, io, empty.dir, .{});
    defer reopened.deinit();
    try testing.expectEqual(null, try reopened.get(item(1, 1, "").key, &value));
    _ = try reopened.write(.{ .entries = &.{item(5, 2, "saved")} });
}

test "compaction rejects tails and corruption before creating segments" {
    if (!db.directory.supported) return error.SkipZigTest;
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    try populate(source.dir);
    const handle = try source.dir.openFile(io, "0000000000000001-0000000000000002.segment", .{ .mode = .read_write });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    try file.writeAll("ZG", try file.length());
    try testing.expectError(error.NeedsRecovery, db.compactTo(testing.allocator, io, source.dir, destination.dir, .{}));
    try file.writeAll("bad!", 48);
    try testing.expectError(error.InvalidMagic, db.compactTo(testing.allocator, io, source.dir, destination.dir, .{}));
    try testing.expectError(error.FileNotFound, destination.dir.statFile(io, "MANIFEST", .{}));
}

test "compaction releases resources on allocation failure" {
    if (!db.directory.supported) return error.SkipZigTest;
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    try populate(source.dir);
    try testing.checkAllAllocationFailures(testing.allocator, compactWithAllocator, .{source.dir});
}

fn compactWithAllocator(allocator: std.mem.Allocator, source: std.Io.Dir) !void {
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    _ = try db.compactTo(allocator, io, source, destination.dir, .{});
}
