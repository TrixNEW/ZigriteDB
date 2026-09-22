const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;

fn key(x: i32) db.Key {
    return item(1, x, "").key;
}

test "hits only match the batch the index points at" {
    var stats: db.Stats = .{};
    var cache = try db.cache.Cache.init(testing.allocator, .{ .bytes = 4096, .shards = 1 });
    defer cache.deinit();
    cache.stats = &stats;
    var output: [16]u8 = undefined;

    try testing.expectEqual(null, cache.get(io, key(0), 1, &output));
    cache.put(io, key(0), 1, "old");
    try testing.expectEqualStrings("old", cache.get(io, key(0), 1, &output).?);
    try testing.expectEqual(null, cache.get(io, key(0), 2, &output));
    try testing.expectEqual(null, cache.get(io, key(0), 1, output[0..2]));

    cache.put(io, key(0), 2, "new");
    try testing.expectEqualStrings("new", cache.get(io, key(0), 2, &output).?);
    // Newer batches win over stale reads.
    cache.put(io, key(0), 1, "old");
    try testing.expectEqualStrings("new", cache.get(io, key(0), 2, &output).?);

    try testing.expectEqual(@as(u64, 3), stats.cache_hits.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), stats.cache_misses.load(.monotonic));
}

test "memory stays under the budget and referenced entries survive a sweep" {
    var stats: db.Stats = .{};
    const budget = 4 * (db.cache.entry_overhead + 8);
    var cache = try db.cache.Cache.init(testing.allocator, .{ .bytes = budget, .shards = 1 });
    defer cache.deinit();
    cache.stats = &stats;
    var output: [8]u8 = undefined;

    for (0..4) |x| cache.put(io, key(@intCast(x)), 1, "12345678");
    _ = cache.get(io, key(0), 1, &output);
    cache.put(io, key(4), 1, "12345678");

    try testing.expect(cache.shards[0].used <= budget);
    try testing.expectEqual(@as(u64, 1), stats.cache_evictions.load(.monotonic));
    try testing.expect(cache.get(io, key(0), 1, &output) != null);
    try testing.expectEqual(null, cache.get(io, key(1), 1, &output));
    try testing.expect(cache.get(io, key(4), 1, &output) != null);

    var huge: [budget + 1]u8 = undefined;
    @memset(&huge, 'x');
    cache.put(io, key(5), 1, &huge);
    try testing.expectEqual(null, cache.get(io, key(5), 1, &huge));
}

fn hammer(cache: *db.cache.Cache, seed: u64, failure: *std.atomic.Value(bool)) void {
    var rng = std.Random.DefaultPrng.init(seed);
    var output: [8]u8 = undefined;
    for (0..20_000) |_| {
        const x = rng.random().intRangeLessThan(i32, 0, 64);
        const batch = rng.random().intRangeLessThan(u64, 1, 4);
        var value: [8]u8 = undefined;
        std.mem.writeInt(i32, value[0..4], x, .little);
        std.mem.writeInt(u32, value[4..8], @intCast(batch), .little);
        if (cache.get(io, key(x), batch, &output)) |hit| {
            if (!std.mem.eql(u8, hit, &value)) failure.store(true, .monotonic);
        } else cache.put(io, key(x), batch, &value);
    }
}

test "concurrent gets and puts never return another key's or batch's bytes" {
    var cache = try db.cache.Cache.init(testing.allocator, .{ .bytes = 16 * (db.cache.entry_overhead + 8), .shards = 4 });
    defer cache.deinit();
    var failure: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, hammer, .{ &cache, i, &failure });
    for (threads) |thread| thread.join();
    try testing.expect(!failure.load(.monotonic));
    for (cache.shards) |shard| try testing.expect(shard.used <= shard.capacity);
}

test "world reads stay correct through overwrites, deletes, compaction and eviction" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{
        .max_open_shards = 1,
        .shard = .{ .stats = &stats },
        .cache = .{ .bytes = 64 * 1024 },
    });
    defer world.deinit();
    var output: [128]u8 = undefined;
    const first = item(1, 0, "first");

    _ = try world.write(.{ .entries = &.{first} });
    try testing.expectEqualStrings("first", (try world.get(first.key, &output)).?);
    try testing.expectEqualStrings("first", (try world.get(first.key, &output)).?);
    try testing.expectEqual(@as(u64, 1), stats.cache_hits.load(.monotonic));

    _ = try world.write(.{ .entries = &.{item(2, 0, "second")} });
    try testing.expectEqualStrings("second", (try world.get(first.key, &output)).?);

    _ = try world.compact(first.key.region());
    try testing.expectEqualStrings("second", (try world.get(first.key, &output)).?);

    // Exercise eviction across regions.
    _ = try world.write(.{ .entries = &.{item(1, 32, "other")} });
    const hits = stats.cache_hits.load(.monotonic);
    try testing.expectEqualStrings("second", (try world.get(first.key, &output)).?);
    try testing.expectEqual(hits + 1, stats.cache_hits.load(.monotonic));

    _ = try world.write(.{ .entries = &.{item(3, 0, null)} });
    try testing.expectEqual(null, try world.get(first.key, &output));

    var results: [1]db.ReadResult = undefined;
    _ = try world.write(.{ .entries = &.{item(4, 0, "fourth")} });
    try world.getMany(&.{.{ .key = first.key, .output = &output }}, &results);
    try testing.expectEqualStrings("fourth", results[0].value);
    try world.getMany(&.{.{ .key = first.key, .output = &output }}, &results);
    try testing.expectEqualStrings("fourth", results[0].value);
    try world.close();
}
