const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;

test "world routes regions and dimensions through a bounded cache" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_shards = 1, .shard = .{ .durability = .buffered } });
    defer world.deinit();
    try testing.expectError(error.DirectoryBusy, db.World.open(testing.allocator, io, tmp.dir, .{}));
    var entries = [_]db.entry.Entry{ item(1, -1, "negative"), item(1, 32, "overworld"), item(1, 32, "nether") };
    entries[0].key.chunk_z = -33;
    entries[2].key.dimension = 1;
    for (entries) |entry| {
        _ = try world.write(.{ .entries = &.{entry} });
        try testing.expectEqual(@as(usize, 1), world.count);
    }
    var output: [128]u8 = undefined;
    for (entries) |entry| try testing.expectEqualStrings(entry.value, (try world.get(entry.key, &output)).?);
    try testing.expectError(error.BatchOrder, world.write(.{ .entries = &.{entries[0]} }));
    try testing.expectEqual(@as(u64, 2), (try world.compact(entries[0].key.region())).?.generation);
    try world.close();
    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_shards = 1 });
    defer reopened.deinit();
    for (entries) |entry| try testing.expectEqualStrings(entry.value, (try reopened.get(entry.key, &output)).?);
    var deleted = item(2, -1, null);
    deleted.key = entries[0].key;
    _ = try reopened.write(.{ .entries = &.{deleted} });
    try testing.expectEqual(null, try reopened.get(deleted.key, &output));
    try reopened.flush();
    try reopened.close();
    try testing.expectError(error.Closed, reopened.get(deleted.key, &output));
}

test "missing reads and rejected batches create no region files" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqual(null, try world.get(item(1, 0, "").key, &output));
    try testing.expectEqual(null, try world.compact(item(1, 0, "").key.region()));
    try testing.expectError(error.RegionMismatch, world.write(.{ .entries = &.{ item(1, 0, "a"), item(1, 32, "b") } }));
    var iterator = world.directory.dir.iterate();
    try testing.expectEqual(null, try iterator.next(io));
}

test "world rejects mismatched region metadata" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = "00000000-00000000-00000000.region";
    try tmp.dir.createDir(io, name, .default_dir);
    const dir = try tmp.dir.openDir(io, name, .{});
    defer dir.close(io);
    var store = try db.Store.create(testing.allocator, io, dir, .{ .dimension = 1, .x = 0, .z = 0 }, .{});
    defer store.deinit();
    try store.close();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    var output: [128]u8 = undefined;
    try testing.expectError(error.RegionMismatch, world.get(item(1, 0, "").key, &output));
}

test "world never follows region symlinks" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "elsewhere", .default_dir);
    try tmp.dir.symLink(io, "elsewhere", "00000000-00000000-00000000.region", .{});
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    try testing.expectError(error.NotDir, world.write(.{ .entries = &.{item(1, 0, "saved")} }));
}

test "world releases its lock even when a shard cannot flush" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    _ = try world.write(.{ .entries = &.{item(1, 0, "saved")} });
    world.slots[0].store.shard.writer.failed = true;
    try testing.expectError(error.WriterFailed, world.close());
    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try reopened.get(item(1, 0, "").key, &output)).?);
}

test "world allocation failures release resources" {
    if (!db.directory.supported) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, worldWithAllocator, .{});
}

fn worldWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(allocator, io, tmp.dir, .{ .max_open_shards = 1, .shard = .{ .batch_buffer_size = 256 } });
    defer world.deinit();
    _ = try world.write(.{ .entries = &.{item(1, 0, "a")} });
    _ = try world.write(.{ .entries = &.{item(1, 32, "b")} });
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("a", (try world.get(item(1, 0, "").key, &output)).?);
    try world.close();
}

test "busy shards stay pinned while other regions write and close waits" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_shards = 2 });
    defer world.deinit();
    _ = try world.write(.{ .entries = &.{item(1, 0, "first")} });
    const first = world.slots[0].store;
    _ = try world.write(.{ .entries = &.{item(1, 32, "second")} });

    first.mutex.lockUncancelable(io);
    var locked = true;
    defer if (locked) first.mutex.unlock(io);
    var read_result: anyerror!void = error.Unexpected;
    const reader = try std.Thread.spawn(.{}, readPinned, .{ &world, &read_result });
    var joined = false;
    defer if (!joined) reader.join();
    // Release the reader even if an assertion fails.
    defer if (locked) {
        first.mutex.unlock(io);
        locked = false;
    };
    while (true) {
        world.mutex.lockUncancelable(io);
        var pinned = false;
        for (world.slots[0..world.count]) |slot| {
            if (slot.store == first) pinned = slot.users != 0;
        }
        world.mutex.unlock(io);
        if (pinned) break;
        std.Thread.yield() catch {};
    }
    _ = try world.write(.{ .entries = &.{item(1, 64, "third")} });
    try testing.expectEqual(@as(usize, 2), world.count);
    var output: [32]u8 = undefined;
    try testing.expectEqualStrings("third", (try world.get(item(1, 64, "").key, &output)).?);

    var close_result: anyerror!void = error.Unexpected;
    const closer = try std.Thread.spawn(.{}, closePinned, .{ &world, &close_result });
    while (true) {
        world.mutex.lockUncancelable(io);
        const closing = world.closing;
        world.mutex.unlock(io);
        if (closing) break;
        std.Thread.yield() catch {};
    }
    const rejected = world.get(item(1, 64, "").key, &output);
    first.mutex.unlock(io);
    locked = false;
    closer.join();
    try testing.expectError(error.Closed, rejected);
    try close_result;
    reader.join();
    joined = true;
    try read_result;
}

fn readPinned(world: *db.World, result: *anyerror!void) void {
    result.* = readFirst(world);
}

fn readFirst(world: *db.World) !void {
    var output: [32]u8 = undefined;
    try testing.expectEqualStrings("first", (try world.get(item(1, 0, "").key, &output)).?);
}

fn closePinned(world: *db.World, result: *anyerror!void) void {
    result.* = world.close();
}
