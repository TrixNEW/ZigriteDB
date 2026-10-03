const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/region.zig");
const region = support.region;
const key = support.key;
const put = support.put;
const batch = support.batch;

test "compaction installs a new generation and reclaims old files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 256, .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "old")}));
    _ = try store.write(batch(2, &.{put(0, "saved")}));
    const unrelated = try tmp.dir.createFile(io, "0000000000000001-0000000000000063.segment", .{ .exclusive = true });
    unrelated.close(io);
    const result = try store.compact();
    try testing.expectEqual(@as(u64, 2), result.generation);
    try testing.expectEqual(@as(usize, 1), result.segment_count);
    try testing.expect(result.output_bytes < (try support.segmentFor(&.{ batch(1, &.{put(0, "old")}), batch(2, &.{put(0, "saved")}) })));
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000063.segment", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "0000000000000001-0000000000000001.segment", .{}));
    try testing.expectEqual(@as(usize, 1), result.cleanup.removed_segments);
    try testing.expect(result.cleanup.synced and result.cleanup.failure == null);
    try testing.expectEqual(error.InvalidGeneration, (try store.reclaim(2, &.{1})).failure.?);
    try testing.expectEqual(@as(usize, 0), (try store.reclaim(1, &.{ 1, 2 })).retained_segments);

    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(key(0), &value)).?);
    _ = try store.write(batch(3, &.{put(0, null)}));
    try testing.expectEqual(@as(u64, 3), (try store.compact()).generation);
    try testing.expectEqual(null, try store.get(key(0), &value));
    try store.close();

    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    try testing.expectEqual(@as(u64, 3), reopened.generation.index.generation);
    try testing.expectEqual(@as(u64, 3), try reopened.lastBatchId());
    try testing.expectError(error.BatchOrder, reopened.write(batch(3, &.{put(1, "late")})));
    _ = try reopened.write(batch(4, &.{put(1, "new")}));
    try reopened.close();
    try testing.expectError(error.Closed, reopened.compact());
}

test "an empty generation keeps the last batch ID across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
        defer store.deinit();
        _ = try store.write(batch(5, &.{put(0, "x")}));
        _ = try store.write(batch(9, &.{put(0, null)}));
        _ = try store.compact();
        try store.close();
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer store.deinit();
    try testing.expectEqual(@as(u64, 9), try store.lastBatchId());
    try testing.expectError(error.BatchOrder, store.write(batch(9, &.{put(0, "y")})));
    try store.close();
}

test "compaction groups each chunk's records together" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats });
    defer store.deinit();
    const at = struct {
        fn entry(x: i32, component: db.Component, value: []const u8) db.Entry {
            return .{ .key = .{ .dimension = 0, .chunk_x = x, .chunk_z = 0, .component = component }, .value = value };
        }
    }.entry;
    var filler: [6000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().bytes(&filler);
    // Interleave two chunks and push their records far apart.
    for (0..4) |round| {
        _ = try store.write(batch(0, &.{ at(1, .version, "a"), at(2, .version, "b") }));
        _ = try store.write(batch(0, &.{at(@intCast(10 + round), .data3d, &filler)}));
        _ = try store.write(batch(0, &.{ at(1, .block_entities, "c"), at(2, .block_entities, "d") }));
        _ = try store.write(batch(0, &.{at(@intCast(20 + round), .data3d, &filler)}));
    }
    var buffer: [16]u8 = undefined;
    var records: [4]db.ChunkRecord = undefined;
    var result: db.ChunkResult = undefined;
    stats.reset();
    try store.getChunk(1, 0, &buffer, &records, &result);
    try testing.expectEqual(@as(u64, 2), stats.disk_reads.load(.monotonic));

    _ = try store.compact();
    stats.reset();
    try store.getChunk(1, 0, &buffer, &records, &result);
    try testing.expectEqual(@as(u64, 1), stats.disk_reads.load(.monotonic));
    try testing.expectEqualStrings("a", records[0].value);
    try testing.expectEqualStrings("c", records[1].value);
    try store.close();
}

test "failed compaction publication keeps the old view and stops writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    (try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true })).close(io);
    try testing.expectError(error.PathAlreadyExists, store.compact());
    try testing.expectEqual(@as(u64, 1), store.generation.index.generation);
    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(key(0), &value)).?);
    try testing.expectError(error.WriterFailed, store.write(batch(2, &.{put(0, "later")})));
    try testing.expectError(error.WriterFailed, store.close());
    var scratch: [512]u8 = undefined;
    var orphans: [4]db.inspection.Orphan = undefined;
    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(@as(?u64, 1), report.generation);
    try testing.expect(report.temporary_manifest);
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000001.segment", .{});
}

test "compaction never overwrites an existing generation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    (try tmp.dir.createFile(io, "0000000000000002-0000000000000001.segment", .{ .exclusive = true })).close(io);
    try testing.expectError(error.PathAlreadyExists, store.compact());
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    try store.close();
}

fn compactWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(allocator, io, tmp.dir, region, .{ .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    _ = store.compact() catch |err| {
        var value: [128]u8 = undefined;
        try testing.expectEqualStrings("saved", (try store.get(key(0), &value)).?);
        try testing.expectEqual(@as(u64, 1), store.generation.index.generation);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "0000000000000002-0000000000000001.segment", .{}));
        return err;
    };
    try store.close();
}

test "compaction allocation failures preserve the current store" {
    try testing.checkAllAllocationFailures(testing.allocator, compactWithAllocator, .{});
}

test "cleanup reports retained paths without interrupting the store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.compact();
    const name = "0000000000000001-0000000000000009.segment";
    try tmp.dir.createDir(io, name, .default_dir);
    const result = try store.reclaim(1, &.{9});
    try testing.expectEqual(@as(usize, 1), result.retained_segments);
    try testing.expect(result.failure != null);
    _ = try tmp.dir.statFile(io, name, .{});
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    try store.close();
}

test "compaction stops writes after live-record corruption" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(1, "keep")}));
    _ = try store.write(batch(2, &.{put(0, "saved")}));
    const file = try support.openFile(tmp.dir, support.segment_name);
    defer file.handle.close(io);
    try file.writeAll("X", db.segment.encoded_len + db.frame.header_len + db.record.header_len);
    try testing.expectError(error.ChecksumMismatch, store.compact());
    try testing.expectEqual(@as(u64, 1), store.generation.index.generation);
    var value: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(key(0), &value)).?);
    try testing.expectError(error.WriterFailed, store.write(batch(3, &.{put(1, "later")})));
    try testing.expectError(error.WriterFailed, store.reclaim(1, &.{1}));
    _ = try tmp.dir.statFile(io, support.segment_name, .{});
}

fn readLoop(store: *db.Store, k: db.Key, iterations: usize, failure: *?anyerror) void {
    var output: [128]u8 = undefined;
    for (0..iterations) |_| {
        const value = store.get(k, &output) catch |err| {
            failure.* = err;
            return;
        };
        if (value == null) failure.* = error.Missing;
    }
}

test "reads during compaction stay safe and see a valid value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 4096, .batch_buffer_size = 512 });
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    var failure: ?anyerror = null;
    const reader = try std.Thread.spawn(.{}, readLoop, .{ &store, key(0), @as(usize, 3000), &failure });
    for (2..22) |id| {
        _ = try store.write(batch(id, &.{put(1, "saved")}));
        _ = try store.compact();
    }
    reader.join();
    try testing.expectEqual(null, failure);
    try store.close();
}

fn getSizedLoop(store: *db.Store, k: db.Key, iterations: usize, failure: *?[]const u8) void {
    var small: [16]u8 = undefined;
    for (0..iterations) |_| {
        var required: usize = 0;
        if (store.getSized(k, &small, &required)) |value| {
            if (value != null and required != 16) failure.* = "size mismatch on success";
        } else |err| {
            if (err != error.BufferTooSmall or required != 512) failure.* = "size mismatch on BufferTooSmall";
        }
    }
}

test "getSized required always matches the size that produced it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 1 << 20, .batch_buffer_size = 4096 });
    defer store.deinit();
    const small_value: [16]u8 = @splat('a');
    _ = try store.write(batch(1, &.{put(0, &small_value)}));
    var failure: ?[]const u8 = null;
    const reader = try std.Thread.spawn(.{}, getSizedLoop, .{ &store, key(0), @as(usize, 3000), &failure });
    const large_value: [512]u8 = @splat('b');
    for (0..1500) |i| {
        const value: []const u8 = if (i % 2 == 0) &large_value else &small_value;
        _ = try store.write(batch(i + 2, &.{put(0, value)}));
    }
    reader.join();
    try testing.expectEqual(null, failure);
    try store.close();
}

test "getMany reads nearby records in one call per segment" {
    var stats: db.Stats = .{};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{
        .max_segments = 3,
        .max_segment_size = try support.segmentFor(&.{batch(1, &.{ put(0, "aa"), put(1, "bb") })}),
        .batch_buffer_size = 256,
        .stats = &stats,
    });
    defer store.deinit();
    _ = try store.write(batch(1, &.{ put(0, "aa"), put(1, "bb") }));
    _ = try store.write(batch(2, &.{ put(2, "cc"), put(3, "dd") }));

    var out: [4][16]u8 = undefined;
    const requests = [_]db.ReadRequest{
        .{ .key = key(0), .output = &out[0] },
        .{ .key = key(1), .output = &out[1] },
        .{ .key = key(2), .output = &out[2] },
        .{ .key = key(3), .output = &out[3] },
    };
    var results: [4]db.ReadResult = undefined;
    stats.reset();
    try store.getMany(&requests, &results);
    for (results) |r| try testing.expectEqual(db.ReadStatus.ok, r.status);
    try testing.expectEqual(@as(u64, 2), stats.disk_reads.load(.monotonic));
    stats.reset();
    for (requests) |request| _ = try store.get(request.key, request.output);
    try testing.expectEqual(@as(u64, 4), stats.disk_reads.load(.monotonic));
    try store.close();
}

fn getManyLoop(store: *db.Store, requests: []const db.ReadRequest, results: []db.ReadResult, failure: *?anyerror) void {
    for (0..1000) |_| {
        store.getMany(requests, results) catch |err| {
            failure.* = err;
            return;
        };
        for (results) |r| if (r.status != .ok) {
            failure.* = error.TestUnexpectedResult;
            return;
        };
    }
}

test "getMany during compaction stays safe" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 4096, .batch_buffer_size = 512 });
    defer store.deinit();
    _ = try store.write(batch(1, &.{ put(0, "aa"), put(1, "bb") }));
    var out: [2][16]u8 = undefined;
    const requests = [_]db.ReadRequest{ .{ .key = key(0), .output = &out[0] }, .{ .key = key(1), .output = &out[1] } };
    var results: [2]db.ReadResult = undefined;
    var failure: ?anyerror = null;
    const reader = try std.Thread.spawn(.{}, getManyLoop, .{ &store, &requests, &results, &failure });
    for (2..22) |id| {
        _ = try store.write(batch(id, &.{put(2, "saved")}));
        _ = try store.compact();
    }
    reader.join();
    try testing.expectEqual(null, failure);
    try store.close();
}

const Churn = struct {
    store: *db.Store,
    rounds: usize,
    failure: ?anyerror = null,

    fn run(self: *Churn) void {
        for (1..self.rounds + 1) |i| {
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, i, .little);
            const x: i32 = @intCast(i % 16);
            _ = self.store.write(batch(i, &.{ put(x, &value), put(16 + x, if (i % 3 == 0) null else &value) })) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
};

fn expectChurned(store: *db.Store, rounds: usize) !void {
    var output: [8]u8 = undefined;
    for (0..16) |x| {
        var last = rounds - (rounds + 16 - x) % 16;
        if (last == 0 or last > rounds) last -= 16;
        const value = (try store.get(key(@intCast(x)), &output)).?;
        try testing.expectEqual(@as(u64, last), std.mem.readInt(u64, value[0..8], .little));
        const other = try store.get(key(@intCast(16 + x)), &output);
        if (last % 3 == 0) try testing.expectEqual(null, other) else try testing.expectEqual(@as(u64, last), std.mem.readInt(u64, other.?[0..8], .little));
    }
}

test "writes keep landing while compaction runs and all of them survive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const options: db.store.Options = .{ .max_segment_size = 64 * 1024, .batch_buffer_size = 1024 };
    const rounds = 3000;
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, options);
        defer store.deinit();
        var churn: Churn = .{ .store = &store, .rounds = rounds };
        const writer = try std.Thread.spawn(.{}, Churn.run, .{&churn});
        for (0..40) |_| _ = try store.compact();
        writer.join();
        try testing.expectEqual(null, churn.failure);
        try expectChurned(&store, rounds);
        _ = try store.compact();
        try expectChurned(&store, rounds);
        try store.close();
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    try testing.expectEqual(@as(u64, rounds), try store.lastBatchId());
    try expectChurned(&store, rounds);
    try store.close();
}

test "stale data asks for compaction once and compaction clears it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .compact_min_bytes = 4096 });
    defer store.deinit();
    const value: [100]u8 = @splat('v');
    var id: u64 = 1;
    while (!store.wantsCompaction()) : (id += 1) {
        try testing.expect(id < 1000);
        _ = try store.write(batch(id, &.{put(0, &value)}));
    }
    try testing.expect(!store.wantsCompaction());
    _ = try store.compact();
    _ = try store.write(batch(id, &.{put(1, &value)}));
    try testing.expect(!store.wantsCompaction());
    try testing.expect(store.generation.index.live_bytes * 2 > store.generation.index.total_bytes);
    try store.close();
}

test "a zero live percentage turns stale hints off" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .compact_min_bytes = 1024, .compact_live_percent = 0 });
    defer store.deinit();
    const value: [100]u8 = @splat('v');
    for (1..200) |id| _ = try store.write(batch(id, &.{put(0, &value)}));
    try testing.expect(!store.wantsCompaction());
    try store.close();
}

test "reopening clears segments of a compaction that never published" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
        defer store.deinit();
        _ = try store.write(batch(1, &.{put(0, "saved")}));
        try store.close();
    }
    for ([_][]const u8{ "0000000000000002-0000000000000001.segment", "0000000000000002-0000000000000002.segment" }) |name| {
        (try tmp.dir.createFile(io, name, .{ .exclusive = true })).close(io);
    }
    (try tmp.dir.createFile(io, "0000000000000003-0000000000000001.segment", .{ .exclusive = true })).close(io);

    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer store.deinit();
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "0000000000000002-0000000000000002.segment", .{}));
    _ = try tmp.dir.statFile(io, "0000000000000003-0000000000000001.segment", .{});
    try testing.expectEqual(@as(u64, 2), (try store.compact()).generation);
    var value: [16]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(key(0), &value)).?);
    try store.close();
}
