const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;

const threads = 8;
const rounds = 50;

const Writer = struct {
    store: *db.Store,
    x: i32,
    last_ok: u64 = 0,
    failure: ?anyerror = null,

    fn run(self: *Writer) void {
        for (1..rounds + 1) |round| {
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, round, .little);
            var entries = [_]db.entry.Entry{item(0, self.x, &value)};
            const result = self.store.writeNext(&entries) catch |err| {
                self.failure = err;
                return;
            };
            if (!result.synced or result.batch_id != entries[0].header.batch_id) self.failure = error.BadResult;
            self.last_ok = round;
        }
    }
};

test "concurrent sync writers share fsyncs and every acknowledged write survives reopen" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    const options: db.shard.Options = .{ .durability = .sync, .stats = &stats };
    var writers: [threads]Writer = undefined;

    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, item(1, 0, "").key.region(), options);
        defer store.deinit();
        var handles: [threads]std.Thread = undefined;
        for (&writers, &handles, 0..) |*writer, *handle, i| {
            writer.* = .{ .store = &store, .x = @intCast(i) };
            handle.* = try std.Thread.spawn(.{}, Writer.run, .{writer});
        }
        for (handles) |handle| handle.join();
        try store.close();
    }

    try testing.expectEqual(@as(u64, threads * rounds), stats.writes.load(.monotonic));
    try testing.expect(stats.fsync_count.load(.monotonic) < threads * rounds);

    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    var output: [8]u8 = undefined;
    for (writers) |writer| {
        try testing.expectEqual(null, writer.failure);
        try testing.expectEqual(@as(u64, rounds), writer.last_ok);
        const value = (try store.get(item(1, writer.x, "").key, &output)).?;
        try testing.expectEqual(writer.last_ok, std.mem.readInt(u64, value[0..8], .little));
    }
    try store.close();
}

test "groups split across runs and segments survive reopen" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    const value = "0123456789012345678901234567890123456789";
    const batch_len = try (db.WriteBatch{ .entries = &.{item(1, 0, value)} }).size();
    const options: db.shard.Options = .{
        .batch_buffer_size = batch_len * 2,
        .max_segment_size = db.segment.encoded_len + batch_len * 3,
        .stats = &stats,
    };

    var values: [10][40]u8 = undefined;
    var entries: [10][1]db.entry.Entry = undefined;
    var batches: [10]db.WriteBatch = undefined;
    for (&values, &entries, &batches, 0..) |*bytes, *batch_entries, *batch, i| {
        bytes.* = value.*;
        bytes[0] = @intCast('a' + i);
        batch_entries.* = .{item(i + 1, @intCast(i % 4), bytes)};
        batch.* = .{ .entries = batch_entries };
    }

    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, item(1, 0, "").key.region(), options);
        defer store.deinit();
        try store.writeGroup(&batches);
        try store.close();
    }
    try testing.expectEqual(@as(u64, 10), stats.writes.load(.monotonic));
    try testing.expect(stats.segment_rotations.load(.monotonic) >= 3);

    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    try testing.expectEqual(@as(u64, 10), try store.lastBatchId());
    var output: [40]u8 = undefined;
    for (6..10) |i| try testing.expectEqualStrings(&values[i], (try store.get(item(1, @intCast(i % 4), "").key, &output)).?);
    try store.close();
}

test "a group with one corrupt batch writes nothing" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, item(1, 0, "").key.region(), .{});
    defer store.deinit();

    var corrupt = item(2, 1, "abc");
    corrupt.header.compression = .lz4;
    corrupt.header.raw_len = 10;
    try testing.expectError(error.InvalidCompressedData, store.writeGroup(&.{
        .{ .entries = &.{item(1, 0, "fine")} },
        .{ .entries = &.{corrupt} },
    }));
    try testing.expectEqual(@as(u64, 0), try store.lastBatchId());
    var output: [8]u8 = undefined;
    try testing.expectEqual(null, try store.get(item(1, 0, "").key, &output));
    try store.writeGroup(&.{.{ .entries = &.{item(1, 0, "fine")} }});
    try testing.expectEqualStrings("fine", (try store.get(item(1, 0, "").key, &output)).?);
    try store.close();
}
