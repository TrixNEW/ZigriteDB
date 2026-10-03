const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/region.zig");
const region = support.region;
const key = support.key;
const put = support.put;
const batch = support.batch;

fn populate(dir: std.Io.Dir, options: db.store.Options) !void {
    var store = try db.Store.create(testing.allocator, io, dir, region, options);
    defer store.deinit();
    for (0..40) |i| {
        var value: [64]u8 = @splat(@truncate(i));
        _ = try store.write(batch(0, &.{ put(@intCast(i % 20), &value), put(@intCast(20 + i % 7), if (i % 5 == 0) null else &value) }));
    }
    try store.close();
}

fn expectPopulated(store: *db.Store) !void {
    var output: [64]u8 = undefined;
    for (0..20) |x| {
        const value = (try store.get(key(@intCast(x)), &output)).?;
        try testing.expectEqual(@as(u8, @intCast(20 + x)), value[0]);
    }
    try testing.expectEqual(@as(u64, 40), try store.lastBatchId());
}

test "a clean close leaves an INDEX that reopens without replaying" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    _ = try tmp.dir.statFile(io, "INDEX", .{});

    // Open trusts INDEX; reads still verify.
    const file = try support.openFile(tmp.dir, support.segment_name);
    defer file.handle.close(io);
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    try expectPopulated(&store);
    try testing.expect(store.checkpointed.offset != 0);
    const live = (try store.generation.index.get(key(0))).?;
    try store.close();

    try file.writeAll("X", live.offset + db.record.header_len);
    var damaged = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer damaged.deinit();
    var output: [64]u8 = undefined;
    try testing.expectError(error.ChecksumMismatch, damaged.get(key(0), &output));
}

test "damaged checkpoints are ignored and rebuilt from segments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    const handle = try tmp.dir.openFile(io, "INDEX", .{ .mode = .read_write });
    const file: db.storage.File = .{ .handle = handle, .io = io };
    const length = try file.length();
    var original: [8192]u8 = undefined;
    try file.readExact(original[0..length], 0);
    handle.close(io);

    var position: usize = 0;
    while (position < length) : (position += 7) {
        var copy = original;
        copy[position] ^= 0x21;
        const damaged = try support.openFile(tmp.dir, "INDEX");
        try damaged.writeAll(copy[0..length], 0);
        damaged.handle.close(io);
        var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
        defer store.deinit();
        try expectPopulated(&store);
    }
    const truncated = try support.openFile(tmp.dir, "INDEX");
    try truncated.handle.setLength(io, length / 2);
    truncated.handle.close(io);
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer store.deinit();
    try expectPopulated(&store);
}

test "writes after the checkpoint are replayed when the session never closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    {
        var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
        defer store.deinit();
        _ = try store.write(batch(41, &.{ put(0, "after"), put(1, null) }));
        try store.flush();
        // No close, so INDEX is stale.
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer store.deinit();
    var output: [64]u8 = undefined;
    try testing.expectEqualStrings("after", (try store.get(key(0), &output)).?);
    try testing.expectEqual(null, try store.get(key(1), &output));
    try testing.expectEqual(@as(u64, 41), try store.lastBatchId());
    try store.close();
}

test "a checkpoint never covers data that later disappeared" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    const file = try support.openFile(tmp.dir, support.segment_name);
    try file.handle.setLength(io, try file.length() - 1);
    file.handle.close(io);
    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, .{}));
}

test "checkpoints from older generations and other options are ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    var old_index: [8192]u8 = undefined;
    const old_len = blk: {
        const file = try support.openFile(tmp.dir, "INDEX");
        defer file.handle.close(io);
        const len = try file.length();
        try file.readExact(old_index[0..len], 0);
        break :blk len;
    };
    {
        var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
        defer store.deinit();
        _ = try store.compact();
        try store.close();
    }
    {
        const file = try support.openFile(tmp.dir, "INDEX");
        defer file.handle.close(io);
        try file.handle.setLength(io, 0);
        try file.writeAll(old_index[0..old_len], 0);
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    try expectPopulated(&store);
    try testing.expectEqual(@as(u64, 2), store.generation.index.generation);
    try store.close();

    // INDEX without fingerprints can't serve skip_unchanged.
    var stats: db.Stats = .{};
    var skipping = try db.Store.open(testing.allocator, io, tmp.dir, .{ .skip_unchanged = true, .stats = &stats });
    defer skipping.deinit();
    var same: [64]u8 = @splat(39);
    const result = try skipping.write(batch(0, &.{put(19, &same)}));
    try testing.expectEqual(result.start, result.end);
    try testing.expectEqual(@as(u64, 1), stats.unchanged_write_skips.load(.monotonic));
    try skipping.close();
}

test "checkpoints span rotated segments" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const options: db.store.Options = .{ .max_segment_size = 1024, .batch_buffer_size = 512 };
    try populate(tmp.dir, options);
    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    try testing.expect(store.generation.count > 2);
    try testing.expectEqual(store.generation.count, store.checkpointed.segments);
    try expectPopulated(&store);
    _ = try store.write(batch(0, &.{put(3, "new")}));
    try store.close();
    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer reopened.deinit();
    var output: [8]u8 = undefined;
    try testing.expectEqualStrings("new", (try reopened.get(key(3), &output)).?);
    try reopened.close();
}
