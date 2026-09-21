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

test "save groups sync buffered batches and reject mixed regions before writing" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .shard = .{ .durability = .buffered } });
    defer world.deinit();
    const batches = [_]db.WriteBatch{
        .{ .entries = &.{item(1, 0, "first")} },
        .{ .entries = &.{ item(2, 0, "last"), item(2, 1, "other") } },
    };
    try testing.expectError(error.RegionMismatch, world.writeGroup(&.{
        batches[0], .{ .entries = &.{item(2, 32, "wrong")} },
    }));
    try testing.expectEqual(@as(usize, 0), world.count);
    try world.writeGroup(&batches);
    const writer = &world.slots[0].store.shard.writer;
    try testing.expectEqual(writer.offset, writer.synced_offset);
    try testing.expectEqual(.buffered, world.slots[0].store.shard.options.durability);
    try testing.expectError(error.BatchOrder, world.writeGroup(&batches));
    try world.close();
    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    var output: [32]u8 = undefined;
    try testing.expectEqualStrings("last", (try reopened.get(item(1, 0, "").key, &output)).?);
    try testing.expectEqualStrings("other", (try reopened.get(item(1, 1, "").key, &output)).?);
}

test "region creation can retry allocation failures without losing files" {
    if (!db.directory.supported) return error.SkipZigTest;
    for (0..32) |offset| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var world = try db.World.open(failing.allocator(), io, tmp.dir, .{});
        defer world.deinit();
        failing.fail_index = failing.alloc_index + offset;
        if (world.write(.{ .entries = &.{item(1, 0, "saved")} })) |_| {
            return;
        } else |err| {
            try testing.expect(err == error.OutOfMemory);
        }
        failing.fail_index = std.math.maxInt(usize);
        _ = try world.write(.{ .entries = &.{item(1, 0, "saved")} });
        var output: [16]u8 = undefined;
        try testing.expectEqualStrings("saved", (try world.get(item(1, 0, "").key, &output)).?);
    }
    return error.AllocationRetriesExhausted;
}

test "missing manifests never overwrite orphaned region data" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = "00000000-00000000-00000000.region";
    try tmp.dir.createDir(io, path, .default_dir);
    const dir = try tmp.dir.openDir(io, path, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, "orphan", .{ .read = true, .exclusive = true });
    defer file.close(io);
    const device: db.storage.File = .{ .handle = file, .io = io };
    try device.writeAll("preserve", 0);
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    try testing.expectError(error.MissingManifest, world.write(.{ .entries = &.{item(1, 0, "new")} }));
    var output: [8]u8 = undefined;
    try device.readExact(&output, 0);
    try testing.expectEqualStrings("preserve", &output);
}

test "getMany across two regions returns correctly-ordered results" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();

    _ = try world.write(.{ .entries = &.{item(1, 0, "region0")} });
    _ = try world.write(.{ .entries = &.{item(1, 32, "region1")} });

    var out0: [16]u8 = undefined;
    var out1: [16]u8 = undefined;
    var miss_out: [16]u8 = undefined;
    // order is deliberately mixed up, plus a miss in a region that was never created
    const requests = [_]db.ReadRequest{
        .{ .key = item(1, 32, "").key, .output = &out1 },
        .{ .key = item(1, 0, "").key, .output = &out0 },
        .{ .key = item(1, 99, "").key, .output = &miss_out },
    };
    var results: [3]db.ReadResult = undefined;
    try world.getMany(&requests, &results);

    try testing.expectEqual(db.ReadStatus.ok, results[0].status);
    try testing.expectEqualStrings("region1", out1[0..results[0].value.len]);
    try testing.expectEqual(db.ReadStatus.ok, results[1].status);
    try testing.expectEqualStrings("region0", out0[0..results[1].value.len]);
    try testing.expectEqual(db.ReadStatus.not_found, results[2].status);
}
