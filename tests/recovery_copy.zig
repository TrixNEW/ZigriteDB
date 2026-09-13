const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const support = @import("support/shard.zig");
const active_name = "0000000000000001-0000000000000002.segment";

fn populate(dir: std.Io.Dir) !void {
    var store = try db.Store.create(testing.allocator, io, dir, support.header.region, .{
        .max_segment_size = 256,
        .batch_buffer_size = 256,
    });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{support.item(1, 0, "saved")} });
    _ = try store.write(.{ .entries = &.{support.item(2, 0, null)} });
    try store.close();
}

test "recovery copies committed batches and leaves the source intact" {
    if (!db.directory.supported) return error.SkipZigTest;
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    try populate(source.dir);

    const handle = try source.dir.openFile(io, active_name, .{ .mode = .read_write });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    const length = try file.length();
    try file.writeAll("ZG", length);
    const temporary = try source.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true });
    temporary.close(io);
    const orphan = try source.dir.createFile(io, "0000000000000001-0000000000000003.segment", .{ .exclusive = true });
    orphan.close(io);

    const result = try db.recovery_copy.recoverTo(testing.allocator, io, source.dir, destination.dir, .{});
    try testing.expectEqual(@as(usize, 2), result.segment_count);
    try testing.expectEqual(@as(u64, 2), result.committed_batches);
    try testing.expectEqual(@as(u64, 2), result.last_batch_id);
    try testing.expectEqual(@as(u64, 2), result.omitted_tail_bytes);
    try testing.expectEqual(length + 2, try file.length());
    _ = try source.dir.statFile(io, "MANIFEST.tmp", .{});
    _ = try source.dir.statFile(io, "0000000000000001-0000000000000003.segment", .{});
    try testing.expectError(error.FileNotFound, destination.dir.statFile(io, "MANIFEST.tmp", .{}));

    var recovered = try db.Store.open(testing.allocator, io, destination.dir, .{});
    defer recovered.deinit();
    var value: [128]u8 = undefined;
    try testing.expectEqual(null, try recovered.get(support.item(1, 0, "").key, &value));
    _ = try recovered.write(.{ .entries = &.{support.item(3, 1, "new")} });
    try recovered.close();
    var reopened = try db.Store.open(testing.allocator, io, destination.dir, .{});
    defer reopened.deinit();
    try testing.expectEqualStrings("new", (try reopened.get(support.item(3, 1, "").key, &value)).?);
}

test "recovery never publishes corrupt data or replaces a destination" {
    if (!db.directory.supported) return error.SkipZigTest;
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    try populate(source.dir);
    try testing.expectError(error.DirectoryBusy, db.recovery_copy.recoverTo(testing.allocator, io, source.dir, source.dir, .{}));
    const handle = try source.dir.openFile(io, active_name, .{ .mode = .read_write });
    defer handle.close(io);
    try (db.storage.File{ .handle = handle, .io = io }).writeAll("bad!", 48);
    try testing.expectError(error.InvalidMagic, db.recovery_copy.recoverTo(testing.allocator, io, source.dir, destination.dir, .{}));
    try testing.expectError(error.FileNotFound, destination.dir.statFile(io, "MANIFEST", .{}));
    try testing.expectError(error.DirectoryNotEmpty, db.recovery_copy.recoverTo(testing.allocator, io, source.dir, destination.dir, .{}));
}

test "recovery releases locks and memory on allocation failure" {
    if (!db.directory.supported) return error.SkipZigTest;
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    try populate(source.dir);
    try testing.checkAllAllocationFailures(testing.allocator, copyWithAllocator, .{source.dir});
}

fn copyWithAllocator(allocator: std.mem.Allocator, source: std.Io.Dir) !void {
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    _ = try db.recovery_copy.recoverTo(allocator, io, source, destination.dir, .{});
}
