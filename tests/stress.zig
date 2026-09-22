const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const item = @import("support/shard.zig").item;

const writers = 4;
const readers = 3;
const rounds = 150;
const regions = 4;

const Shared = struct {
    world: *db.World,
    acknowledged: [writers]std.atomic.Value(u64) = .{std.atomic.Value(u64).init(0)} ** writers,
    done: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(u32) = .init(0),

    fn fail(self: *Shared, code: u32) void {
        _ = self.failure.cmpxchgStrong(0, code, .monotonic, .monotonic);
    }
};

fn key(writer: usize, region: usize) db.Key {
    return item(0, @intCast(writer + region * 32), "").key;
}

fn write(shared: *Shared, writer: usize) void {
    var rng = std.Random.DefaultPrng.init(writer);
    for (1..rounds + 1) |sequence| {
        const region = rng.random().uintLessThan(usize, regions);
        var value: [16]u8 = undefined;
        std.mem.writeInt(u64, value[0..8], writer, .little);
        std.mem.writeInt(u64, value[8..16], sequence, .little);
        var entries = [_]db.entry.Entry{item(0, @intCast(writer + region * 32), &value)};
        _ = shared.world.writeNext(&entries) catch return shared.fail(1);
        shared.acknowledged[writer].store(sequence, .release);
    }
}

fn read(shared: *Shared, seed: u64) void {
    var rng = std.Random.DefaultPrng.init(seed);
    var output: [16]u8 = undefined;
    var seen = [_][regions]u64{[_]u64{0} ** regions} ** writers;
    while (!shared.done.load(.acquire)) {
        const writer = rng.random().uintLessThan(usize, writers);
        const region = rng.random().uintLessThan(usize, regions);
        const value = (shared.world.get(key(writer, region), &output) catch return shared.fail(2)) orelse continue;
        if (value.len != 16 or std.mem.readInt(u64, value[0..8], .little) != writer) return shared.fail(3);
        const sequence = std.mem.readInt(u64, value[8..16], .little);
        if (sequence > shared.acknowledged[writer].load(.acquire) + 1) return shared.fail(4);
        if (sequence < seen[writer][region]) return shared.fail(6);
        seen[writer][region] = sequence;
    }
}

fn compact(shared: *Shared) void {
    var region: i32 = 0;
    while (!shared.done.load(.acquire)) : (region = @mod(region + 1, regions)) {
        _ = shared.world.compact(.{ .dimension = 0, .x = region, .z = 0 }) catch return shared.fail(5);
    }
}

test "readers, writers, compaction, eviction and the cache all agree with the writers' history" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{
        .max_open_shards = 2,
        .shard = .{ .max_segment_size = 4096, .batch_buffer_size = 1024 },
        .cache = .{ .bytes = 2048, .shards = 2 },
    });
    defer world.deinit();
    var shared: Shared = .{ .world = &world };

    var threads: [writers + readers + 1]std.Thread = undefined;
    for (threads[0..writers], 0..) |*thread, w| thread.* = try std.Thread.spawn(.{}, write, .{ &shared, w });
    for (threads[writers..][0..readers], 0..) |*thread, r| thread.* = try std.Thread.spawn(.{}, read, .{ &shared, 100 + r });
    threads[writers + readers] = try std.Thread.spawn(.{}, compact, .{&shared});
    for (threads[0..writers]) |thread| thread.join();
    shared.done.store(true, .release);
    for (threads[writers..]) |thread| thread.join();
    try testing.expectEqual(@as(u32, 0), shared.failure.load(.monotonic));
    try world.close();

    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    var output: [16]u8 = undefined;
    for (0..writers) |writer| {
        var last = [_]u64{0} ** regions;
        var rng = std.Random.DefaultPrng.init(writer);
        for (1..rounds + 1) |sequence| last[rng.random().uintLessThan(usize, regions)] = sequence;
        for (last, 0..) |sequence, region| {
            const value = try reopened.get(key(writer, region), &output);
            if (sequence == 0) {
                try testing.expectEqual(null, value);
            } else {
                try testing.expectEqual(sequence, std.mem.readInt(u64, value.?[8..16], .little));
            }
        }
    }
    try reopened.close();
}
