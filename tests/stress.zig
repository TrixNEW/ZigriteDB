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

const hot_rounds = 400;

const Hot = struct {
    world: *db.World,
    done: std.atomic.Value(bool) = .init(false),
    progress: std.atomic.Value(usize) = .init(0),
    failure: std.atomic.Value(u32) = .init(0),

    fn fail(self: *Hot, code: u32) void {
        _ = self.failure.cmpxchgStrong(0, code, .monotonic, .monotonic);
    }
};

const hot_key = item(0, 0, "").key;

fn growKey(sequence: usize) db.Key {
    return .{ .dimension = 0, .chunk_x = @intCast(sequence % 32), .chunk_z = @intCast(1 + sequence / 32), .component = .metadata };
}

/// Value format: sequence id plus a low-byte fill.
fn hotValue(sequence: u64, buffer: *[128]u8) []const u8 {
    const len = 8 + sequence % 120;
    std.mem.writeInt(u64, buffer[0..8], sequence, .little);
    @memset(buffer[8..len], @truncate(sequence));
    return buffer[0..len];
}

fn validHot(value: []const u8) bool {
    if (value.len < 8) return false;
    var expected: [128]u8 = undefined;
    return std.mem.eql(u8, value, hotValue(std.mem.readInt(u64, value[0..8], .little), &expected));
}

fn writeHot(hot: *Hot) void {
    defer hot.done.store(true, .release);
    var buffer: [128]u8 = undefined;
    for (1..hot_rounds + 1) |sequence| {
        var entries = [_]db.entry.Entry{item(0, 0, hotValue(sequence, &buffer))};
        _ = hot.world.writeNext(&entries) catch return hot.fail(1);
        var grow = [_]db.entry.Entry{item(0, 0, "g")};
        grow[0].key = growKey(sequence);
        _ = hot.world.writeNext(&grow) catch return hot.fail(1);
        hot.progress.store(sequence, .release);
    }
}

fn readHot(hot: *Hot) void {
    var output: [128]u8 = undefined;
    while (!hot.done.load(.acquire)) {
        const value = (hot.world.get(hot_key, &output) catch return hot.fail(2)) orelse continue;
        if (!validHot(value)) return hot.fail(3);
    }
}

fn readHotMany(hot: *Hot) void {
    var outputs: [3][128]u8 = undefined;
    var sequence: usize = 1;
    while (!hot.done.load(.acquire)) : (sequence = sequence % hot_rounds + 1) {
        const requests = [_]db.ReadRequest{
            .{ .key = hot_key, .output = &outputs[0] },
            .{ .key = growKey(sequence), .output = &outputs[1] },
            .{ .key = hot_key, .output = outputs[2][0..8] },
        };
        var results: [3]db.ReadResult = undefined;
        hot.world.getMany(&requests, &results) catch return hot.fail(4);
        if (results[0].status == .ok and !validHot(results[0].value)) return hot.fail(5);
        if (results[1].status == .ok and !std.mem.eql(u8, results[1].value, "g")) return hot.fail(6);
        if (results[2].status == .ok and !validHot(results[2].value)) return hot.fail(7);
    }
}

fn compactHot(hot: *Hot) void {
    // Compact every few writes so the writer does not starve.
    var last: usize = 0;
    while (!hot.done.load(.acquire)) {
        const progress = hot.progress.load(.acquire);
        if (progress < last + 16) {
            std.Thread.yield() catch {};
            continue;
        }
        last = progress;
        _ = hot.world.compact(.{ .dimension = 0, .x = 0, .z = 0 }) catch return hot.fail(8);
    }
}

test "same-key size-changing overwrites, index growth, rotation and compaction never tear a read" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{
        .shard = .{ .max_segment_size = 4096, .batch_buffer_size = 1024 },
        .cache = .{ .bytes = 1024, .shards = 2 },
    });
    defer world.deinit();
    var hot: Hot = .{ .world = &world };

    var threads: [5]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, writeHot, .{&hot});
    threads[1] = try std.Thread.spawn(.{}, readHot, .{&hot});
    threads[2] = try std.Thread.spawn(.{}, readHot, .{&hot});
    threads[3] = try std.Thread.spawn(.{}, readHotMany, .{&hot});
    threads[4] = try std.Thread.spawn(.{}, compactHot, .{&hot});
    for (threads) |thread| thread.join();
    try testing.expectEqual(@as(u32, 0), hot.failure.load(.monotonic));

    var output: [128]u8 = undefined;
    var expected: [128]u8 = undefined;
    try testing.expectEqualStrings(hotValue(hot_rounds, &expected), (try world.get(hot_key, &output)).?);
    try world.close();
}
