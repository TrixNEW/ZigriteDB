const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;

test "skip_unchanged drops no-op puts and deletes but keeps every real change" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    const options: db.shard.Options = .{ .stats = &stats, .skip_unchanged = true };
    var output: [32]u8 = undefined;

    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, item(1, 0, "").key.region(), options);
        defer store.deinit();
        _ = try store.write(.{ .entries = &.{ item(1, 0, "same"), item(1, 1, "other") } });

        const skipped = try store.write(.{ .entries = &.{item(2, 0, "same")} });
        try testing.expectEqual(skipped.start, skipped.end);
        try testing.expectEqual(@as(u64, 1), try store.lastBatchId());
        _ = try store.write(.{ .entries = &.{item(3, 5, null)} });
        try testing.expectEqual(@as(u64, 2), stats.unchanged_write_skips.load(.monotonic));
        try testing.expectEqual(@as(u64, 1), stats.writes.load(.monotonic));

        _ = try store.write(.{ .entries = &.{ item(4, 0, "same"), item(4, 1, "diff!") } });
        try testing.expectEqual(@as(u64, 3), stats.records_written.load(.monotonic));
        try testing.expectEqualStrings("diff!", (try store.get(item(1, 1, "").key, &output)).?);

        // Same length, different bytes.
        _ = try store.write(.{ .entries = &.{item(5, 0, "SAME")} });
        try testing.expectEqualStrings("SAME", (try store.get(item(1, 0, "").key, &output)).?);

        // The last occurrence wins inside a batch.
        _ = try store.write(.{ .entries = &.{ item(6, 1, "changed"), item(6, 1, "diff!") } });
        try testing.expectEqualStrings("diff!", (try store.get(item(1, 1, "").key, &output)).?);

        _ = try store.write(.{ .entries = &.{item(7, 1, null)} });
        try testing.expectEqual(null, try store.get(item(1, 1, "").key, &output));
        try store.close();
    }

    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    const skips = stats.unchanged_write_skips.load(.monotonic);
    const skipped = try store.write(.{ .entries = &.{item(8, 0, "SAME")} });
    try testing.expectEqual(skipped.start, skipped.end);
    try testing.expectEqual(skips + 1, stats.unchanged_write_skips.load(.monotonic));
    try store.close();
}
