const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/region.zig");
const region = support.region;
const key = support.key;
const put = support.put;
const batch = support.batch;
const segment_name = support.segment_name;

fn small() !db.store.Options {
    return .{
        .max_keys = 8,
        .max_segments = 3,
        .max_segment_size = try support.segmentFor(&.{batch(1, &.{put(0, "saved")})}),
        .batch_buffer_size = 256,
    };
}

test "writes and deletes become readable together" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    var output: [128]u8 = undefined;

    _ = try store.write(batch(1, &.{ put(0, "old"), put(1, "gone") }));
    _ = try store.write(batch(2, &.{ put(0, "new"), put(1, null) }));

    try testing.expectEqualStrings("new", (try store.get(key(0), &output)).?);
    try testing.expectEqual(null, try store.get(key(1), &output));
    try store.close();
}

test "ID zero takes the next ID and explicit IDs must increase" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    try testing.expectEqual(@as(u64, 1), (try store.write(batch(0, &.{put(0, "a")}))).batch_id);
    try testing.expectEqual(@as(u64, 7), (try store.write(batch(7, &.{put(0, "b")}))).batch_id);
    try testing.expectError(error.BatchOrder, store.write(batch(7, &.{put(0, "c")})));
    try testing.expectEqual(@as(u64, 8), (try store.write(batch(0, &.{put(0, "d")}))).batch_id);
    try testing.expectEqual(@as(u64, 8), try store.lastBatchId());
    try store.close();
}

test "failed writes leave the old index visible and stop the writer" {
    for ([_]bool{ false, true }) |sync_failure| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .durability = .sync });
        defer store.deinit();
        _ = try store.write(batch(1, &.{put(0, "old")}));

        var faults: db.storage.Faults = .{ .fail_sync = sync_failure, .fail_write = !sync_failure };
        support.inject(&faults);
        defer support.clearFaults();
        const expected = if (sync_failure) error.InputOutput else error.NoSpaceLeft;
        try testing.expectError(expected, store.write(batch(2, &.{ put(0, "new"), put(1, "extra") })));
        support.clearFaults();

        var output: [128]u8 = undefined;
        if (sync_failure) {
            // Published before the fsync failed.
            try testing.expectEqualStrings("new", (try store.get(key(0), &output)).?);
        } else {
            try testing.expectEqualStrings("old", (try store.get(key(0), &output)).?);
            try testing.expectEqual(null, try store.get(key(1), &output));
        }
        try testing.expectError(error.WriterFailed, store.write(batch(3, &.{put(0, "later")})));
    }
}

test "index limits are checked before writing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_keys = 1 });
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "old")}));
    const length = try support.segmentLength(tmp.dir);

    try testing.expectError(error.IndexFull, store.write(batch(2, &.{put(1, "extra")})));
    try testing.expectEqual(length, try support.segmentLength(tmp.dir));
    _ = try store.write(batch(2, &.{ put(0, null), put(1, "new") }));
    try store.close();
}

fn writeWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "old")}));
    const length = try support.segmentLength(tmp.dir);
    var entries: [12]db.Entry = undefined;
    for (&entries, 0..) |*value, x| value.* = put(@intCast(x), "new");

    _ = store.write(batch(2, &entries)) catch |err| {
        try testing.expectEqual(length, try support.segmentLength(tmp.dir));
        var output: [128]u8 = undefined;
        try testing.expectEqualStrings("old", (try store.get(key(0), &output)).?);
        return err;
    };
    try store.close();
}

test "allocation failure cannot reach the disk write" {
    try testing.checkAllAllocationFailures(testing.allocator, writeWithAllocator, .{});
}

fn competingWrite(store: *db.Store, result: *?anyerror) void {
    _ = store.write(batch(1, &.{put(0, "value")})) catch |err| {
        result.* = err;
        return;
    };
    result.* = null;
}

test "concurrent writes cannot publish the same batch twice" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    var first_result: ?anyerror = null;
    var second_result: ?anyerror = null;
    const first = try std.Thread.spawn(.{}, competingWrite, .{ &store, &first_result });
    {
        defer first.join();
        const second = try std.Thread.spawn(.{}, competingWrite, .{ &store, &second_result });
        second.join();
    }
    try testing.expect((first_result == null) != (second_result == null));
    try testing.expectEqual(error.BatchOrder, first_result orelse second_result.?);
    try store.close();
}

test "close flushes buffered writes and rejects later calls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    try testing.expect(!(try store.write(batch(1, &.{put(0, "value")}))).synced);
    try store.close();
    try store.close();

    var output: [128]u8 = undefined;
    try testing.expectError(error.Closed, store.get(key(0), &output));
    try testing.expectError(error.Closed, store.flush());
    try testing.expectError(error.Closed, store.write(batch(2, &.{put(0, "later")})));
}

test "close frees memory even when sync fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "value")}));
    var faults: db.storage.Faults = .{ .fail_sync = true };
    support.inject(&faults);
    defer support.clearFaults();
    try testing.expectError(error.InputOutput, store.close());
    try testing.expectError(error.Closed, store.flush());
}

test "store rotates automatically and restores data after close" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: [128]u8 = undefined;
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
        defer store.deinit();
        try testing.expectError(error.DirectoryBusy, db.Store.open(testing.allocator, io, tmp.dir, try small()));
        _ = try store.write(batch(1, &.{put(0, "saved")}));
        _ = try store.write(batch(2, &.{put(1, "saved")}));
        _ = try store.write(batch(3, &.{put(0, null)}));
        try testing.expectEqual(@as(usize, 3), store.generation.count);
        try testing.expectEqualStrings("saved", (try store.get(key(1), &output)).?);
        try testing.expectEqual(null, try store.get(key(0), &output));
        try testing.expectError(error.TooManySegments, store.write(batch(4, &.{put(2, "saved")})));
        try store.close();
        try testing.expectError(error.Closed, store.flush());
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, try small());
    defer store.deinit();
    try testing.expectEqualStrings("saved", (try store.get(key(1), &output)).?);
    try testing.expectEqual(null, try store.get(key(0), &output));
    try store.close();
}

test "a failed rotation publication stops writes and keeps what was there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
        defer store.deinit();
        _ = try store.write(batch(1, &.{put(0, "saved")}));
        (try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true })).close(io);
        try testing.expectError(error.PathAlreadyExists, store.write(batch(2, &.{put(1, "next")})));
        try testing.expectError(error.WriterFailed, store.write(batch(3, &.{put(1, "later")})));
        try tmp.dir.deleteFile(io, "MANIFEST.tmp");
    }
    // Left behind, then cleared on open.
    _ = try tmp.dir.statFile(io, "0000000000000001-0000000000000002.segment", .{});
    var store = try db.Store.open(testing.allocator, io, tmp.dir, try small());
    defer store.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(key(0), &output)).?);
    try testing.expectEqual(null, try store.get(key(1), &output));
    _ = try store.write(batch(2, &.{put(1, "next")}));
    try store.close();
}

test "a failed sync before rotation stops writes before any new segment is published" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    var faults: db.storage.Faults = .{ .fail_sync = true };
    support.inject(&faults);
    defer support.clearFaults();
    try testing.expectError(error.InputOutput, store.write(batch(2, &.{put(1, "next")})));
    support.clearFaults();
    try testing.expectError(error.WriterFailed, store.write(batch(3, &.{put(1, "later")})));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "0000000000000001-0000000000000002.segment", .{}));
}

test "open restores data, accepts new writes, and refuses partial tails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
        defer store.deinit();
        _ = try store.write(batch(1, &.{put(0, "saved")}));
        try store.close();
    }
    var output: [128]u8 = undefined;
    {
        var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
        defer store.deinit();
        try testing.expectEqualStrings("saved", (try store.get(key(0), &output)).?);
        _ = try store.write(batch(2, &.{put(0, "updated")}));
        try testing.expectEqualStrings("updated", (try store.get(key(0), &output)).?);
        try store.close();
    }
    {
        // INDEX lets open skip its fsyncs.
        var faults: db.storage.Faults = .{ .fail_sync = true };
        support.inject(&faults);
        defer support.clearFaults();
        var clean = try db.Store.open(testing.allocator, io, tmp.dir, .{});
        clean.deinit();
        try tmp.dir.deleteFile(io, "INDEX");
        try testing.expectError(error.InputOutput, db.Store.open(testing.allocator, io, tmp.dir, .{}));
    }
    const file = try support.openFile(tmp.dir, segment_name);
    defer file.handle.close(io);
    try file.handle.setLength(io, try file.length() - 1);
    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, .{}));
}

test "losing unsynced writes preserves the last flushed batch" {
    for ([_]bool{ false, true }) |flush| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var synced: u64 = 0;
        {
            var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
            defer store.deinit();
            _ = try store.write(batch(1, &.{put(0, "saved")}));
            try store.flush();
            _ = try store.write(batch(2, &.{ put(0, "new"), put(1, "extra") }));
            if (flush) try store.flush();
            synced = store.synced_offset;
        }
        // Drop unsynced bytes, as a power cut would.
        const file = try support.openFile(tmp.dir, segment_name);
        try file.handle.setLength(io, synced);
        file.handle.close(io);

        var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{});
        defer reopened.deinit();
        var value: [128]u8 = undefined;
        try testing.expectEqualStrings(if (flush) "new" else "saved", (try reopened.get(key(0), &value)).?);
        const extra = try reopened.get(key(1), &value);
        if (flush) try testing.expectEqualStrings("extra", extra.?) else try testing.expectEqual(null, extra);
        try testing.expectEqual(@as(u64, if (flush) 2 else 1), try reopened.lastBatchId());
    }
}

test "garbage and zero-filled tails need recovery instead of failing as corruption" {
    for ([_]u8{ 0, 0xa5 }) |fill| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
            defer store.deinit();
            _ = try store.write(batch(1, &.{put(0, "saved")}));
            try store.close();
        }
        const file = try support.openFile(tmp.dir, segment_name);
        var junk: [100]u8 = @splat(fill);
        try file.writeAll(&junk, try file.length());
        file.handle.close(io);
        try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, .{}));
    }
}

test "create never replaces an existing store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    try store.close();

    try testing.expectError(error.DirectoryNotEmpty, db.Store.create(testing.allocator, io, tmp.dir, region, try small()));
    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, try small());
    defer reopened.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try reopened.get(key(0), &output)).?);
}

test "unfinished publication blocks startup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    try store.close();
    (try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true })).close(io);
    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, try small()));
    try tmp.dir.deleteFile(io, "MANIFEST.tmp");
    try tmp.dir.deleteFile(io, segment_name);
    try testing.expectError(error.MissingSegment, db.Store.open(testing.allocator, io, tmp.dir, try small()));
}

test "manifest and segment symlinks are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    try store.close();
    for ([_][]const u8{ "MANIFEST", segment_name }) |name| {
        try tmp.dir.rename(name, tmp.dir, "backup", io);
        try tmp.dir.symLink(io, "backup", name, .{});
        try testing.expectError(error.SymlinkNotAllowed, db.Store.open(testing.allocator, io, tmp.dir, try small()));
        try tmp.dir.deleteFile(io, name);
        try tmp.dir.rename("backup", tmp.dir, name, io);
    }
}

test "manifest size and file type are checked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "MANIFEST", .default_dir);
    try testing.expectError(error.NotRegularFile, db.Store.open(testing.allocator, io, tmp.dir, try small()));

    var other = testing.tmpDir(.{});
    defer other.cleanup();
    const file = try other.dir.createFile(io, "MANIFEST", .{ .exclusive = true });
    try file.setLength(io, db.manifest.max_encoded_len + 1);
    file.close(io);
    try testing.expectError(error.ManifestTooLarge, db.Store.open(testing.allocator, io, other.dir, try small()));
}

test "a v1 manifest asks for migration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    try store.close();
    const file = try support.openFile(tmp.dir, "MANIFEST");
    defer file.handle.close(io);
    try file.writeAll(&.{ 1, 0 }, 4);
    try testing.expectError(error.NeedsMigration, db.Store.open(testing.allocator, io, tmp.dir, .{}));
}

fn openWithAllocator(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var store = try db.Store.open(allocator, io, dir, try small());
    defer store.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(key(0), &output)).?);
}

test "failed opens release allocations and locks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    try store.close();
    try testing.checkAllAllocationFailures(testing.allocator, openWithAllocator, .{tmp.dir});
}

fn createWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    try store.close();
}

test "failed creates release resources" {
    try testing.checkAllAllocationFailures(testing.allocator, createWithAllocator, .{});
}

const ReadOutcome = struct { len: ?usize = null, err: ?anyerror = null };

fn concurrentRead(store: *db.Store, k: db.Key, buffer: []u8, result: *ReadOutcome) void {
    if (store.get(k, buffer)) |value| {
        result.len = if (value) |v| v.len else null;
    } else |err| {
        result.err = err;
    }
}

test "concurrent same-key reads all see the correct value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "shared")}));
    var buffers: [8][128]u8 = undefined;
    var results: [8]ReadOutcome = @splat(.{});
    var threads: [8]std.Thread = undefined;
    for (0..8) |i| threads[i] = try std.Thread.spawn(.{}, concurrentRead, .{ &store, key(0), &buffers[i], &results[i] });
    for (threads) |t| t.join();
    for (0..8) |i| {
        try testing.expectEqual(null, results[i].err);
        try testing.expectEqualStrings("shared", buffers[i][0 .. results[i].len orelse 0]);
    }
    try testing.expectEqual(@as(usize, 0), store.generation.readers.load(.seq_cst));
    try store.close();
}

test "a corrupted read releases its pin so close does not hang" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "old")}));
    const file = try support.openFile(tmp.dir, segment_name);
    defer file.handle.close(io);
    try file.writeAll("X", db.segment.encoded_len + db.frame.header_len + db.record.header_len);

    var output: [128]u8 = undefined;
    try testing.expectError(error.ChecksumMismatch, store.get(key(0), &output));
    try testing.expectEqual(@as(usize, 0), store.generation.readers.load(.seq_cst));
    try store.close();
}

test "getMany resolves keys with independent statuses and one pin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "hello")}));
    _ = try store.write(batch(2, &.{put(1, "bb")}));

    var big: [16]u8 = undefined;
    var tiny: [2]u8 = undefined;
    var other: [16]u8 = undefined;
    var miss: [16]u8 = undefined;
    const requests = [_]db.ReadRequest{
        .{ .key = key(0), .output = &big },
        .{ .key = key(0), .output = &tiny },
        .{ .key = key(1), .output = &other },
        .{ .key = key(5), .output = &miss },
    };
    var results: [4]db.ReadResult = undefined;
    try store.getMany(&requests, &results);
    try testing.expectEqual(db.ReadStatus.ok, results[0].status);
    try testing.expectEqualStrings("hello", results[0].value);
    try testing.expectEqual(db.ReadStatus.buffer_too_small, results[1].status);
    try testing.expectEqual(@as(usize, 5), results[1].required);
    try testing.expectEqualStrings("bb", results[2].value);
    try testing.expectEqual(db.ReadStatus.not_found, results[3].status);
    try testing.expectEqual(@as(usize, 0), store.generation.readers.load(.seq_cst));

    var too_many: [db.store.max_batch_keys + 1]db.ReadRequest = undefined;
    var too_many_results: [db.store.max_batch_keys + 1]db.ReadResult = undefined;
    for (&too_many) |*r| r.* = .{ .key = key(0), .output = &big };
    try testing.expectError(error.TooManyKeys, store.getMany(&too_many, &too_many_results));
    try store.close();
}

test "getChunk returns every component of a chunk in key order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats });
    defer store.deinit();
    const at = struct {
        fn entry(component: db.Component, y: i32, value: ?[]const u8) db.Entry {
            return .{ .key = .{ .dimension = 0, .chunk_x = 3, .chunk_z = 4, .component = component, .subchunk_y = y }, .value = value };
        }
    }.entry;
    var big: [3000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i / 100);
    _ = try store.write(batch(1, &.{ at(.subchunk, 2, "two"), at(.version, 0, "v"), at(.subchunk, -4, &big), at(.data3d, 0, "biomes") }));
    _ = try store.write(batch(2, &.{ at(.block_entities, 0, "tile"), at(.subchunk, 2, null) }));

    var buffer: [4096]u8 = undefined;
    var records: [8]db.ChunkRecord = undefined;
    var result: db.ChunkResult = undefined;
    stats.reset();
    try store.getChunk(3, 4, &buffer, &records, &result);
    try testing.expectEqual(@as(usize, 4), result.count);
    try testing.expectEqual(@as(usize, 6 + 1 + big.len + 4), result.required);
    try testing.expectEqual(db.Component.data3d, records[0].component);
    try testing.expectEqualStrings("biomes", records[0].value);
    try testing.expectEqual(db.Component.version, records[1].component);
    try testing.expectEqual(db.Component.subchunk, records[2].component);
    try testing.expectEqual(@as(i8, -4), records[2].subchunk_y);
    try testing.expectEqualSlices(u8, &big, records[2].value);
    try testing.expectEqualStrings("tile", records[3].value);
    try testing.expectEqual(@as(u64, 1), stats.disk_reads.load(.monotonic));

    try testing.expectError(error.BufferTooSmall, store.getChunk(3, 4, buffer[0..10], &records, &result));
    try testing.expectEqual(@as(usize, 4), result.count);
    try testing.expectError(error.BufferTooSmall, store.getChunk(3, 4, &buffer, records[0..2], &result));
    try store.getChunk(5, 5, &buffer, &records, &result);
    try testing.expectEqual(@as(usize, 0), result.count);
    try testing.expectError(error.RegionMismatch, store.getChunk(40, 4, &buffer, &records, &result));
    try store.close();
}

test "getChunk handles chunks with more components than fit on the stack" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    var entries: [200]db.Entry = undefined;
    var values: [200][2]u8 = undefined;
    for (&entries, &values, 0..) |*entry, *value, i| {
        value.* = .{ @truncate(i), @truncate(i >> 8) };
        entry.* = .{ .key = .{ .dimension = 0, .chunk_x = 1, .chunk_z = 1, .component = .subchunk, .subchunk_y = @as(i32, @intCast(i)) - 100 }, .value = value };
    }
    _ = try store.write(batch(1, &entries));
    var buffer: [400]u8 = undefined;
    var records: [200]db.ChunkRecord = undefined;
    var result: db.ChunkResult = undefined;
    try store.getChunk(1, 1, &buffer, &records, &result);
    try testing.expectEqual(@as(usize, 200), result.count);
    for (records, 0..) |record, i| {
        try testing.expectEqual(@as(i8, @intCast(@as(i32, @intCast(i)) - 100)), record.subchunk_y);
        try testing.expectEqualSlices(u8, &values[i], record.value);
    }
    try store.close();
}

fn concurrentGetMany(store: *db.Store, requests: []const db.ReadRequest, results: []db.ReadResult, err: *?anyerror) void {
    store.getMany(requests, results) catch |e| {
        err.* = e;
    };
}

fn churn(store: *db.Store, first_id: u64) !void {
    _ = try store.write(batch(first_id, &.{put(0, "a much longer replacement value")}));
    for (0..2) |round| {
        var entries: [12]db.Entry = undefined;
        for (&entries, 0..) |*value, i| value.* = put(@intCast(1 + round * 12 + i), "grow");
        _ = try store.write(batch(first_id + 1 + round, &entries));
    }
    _ = try store.write(batch(first_id + 3, &.{put(0, null)}));
}

test "a pinned get reads its captured location while writers overwrite, grow and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "old")}));

    var faults: db.storage.Faults = .{};
    support.inject(&faults);
    defer support.clearFaults();
    faults.armed.store(true, .release);
    var output: [3]u8 = undefined;
    var result: ReadOutcome = .{};
    const reader = try std.Thread.spawn(.{}, concurrentRead, .{ &store, key(0), &output, &result });
    faults.waitPaused();
    try churn(&store, 2);
    faults.released.store(true, .release);
    reader.join();

    try testing.expectEqual(null, result.err);
    try testing.expectEqualStrings("old", output[0..result.len.?]);
    try testing.expectEqual(@as(usize, 0), store.generation.readers.load(.seq_cst));
    var fresh: [3]u8 = undefined;
    try testing.expectEqual(null, try store.get(key(0), &fresh));
    try store.close();
}

test "a pinned getMany reads its captured locations while writers overwrite, grow and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{ put(0, "old"), put(30, "kept") }));

    var faults: db.storage.Faults = .{};
    support.inject(&faults);
    defer support.clearFaults();
    faults.armed.store(true, .release);
    var out0: [3]u8 = undefined;
    var out1: [4]u8 = undefined;
    const requests = [_]db.ReadRequest{ .{ .key = key(0), .output = &out0 }, .{ .key = key(30), .output = &out1 } };
    var results: [2]db.ReadResult = undefined;
    var err: ?anyerror = null;
    const reader = try std.Thread.spawn(.{}, concurrentGetMany, .{ &store, &requests, &results, &err });
    faults.waitPaused();
    try churn(&store, 2);
    faults.released.store(true, .release);
    reader.join();

    try testing.expectEqual(null, err);
    try testing.expectEqualStrings("old", results[0].value);
    try testing.expectEqualStrings("kept", results[1].value);
    try testing.expectEqual(@as(usize, 0), store.generation.readers.load(.seq_cst));
    try store.close();
}

test "a pinned get survives rotation and a newer write to the new segment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try small());
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));

    var faults: db.storage.Faults = .{};
    support.inject(&faults);
    defer support.clearFaults();
    faults.armed.store(true, .release);
    var output: [16]u8 = undefined;
    var result: ReadOutcome = .{};
    const reader = try std.Thread.spawn(.{}, concurrentRead, .{ &store, key(0), &output, &result });
    faults.waitPaused();
    _ = try store.write(batch(2, &.{put(0, "later")}));
    try testing.expectEqual(@as(usize, 2), store.generation.count);
    faults.released.store(true, .release);
    reader.join();

    try testing.expectEqual(null, result.err);
    try testing.expectEqualStrings("saved", output[0..result.len.?]);
    var fresh: [16]u8 = undefined;
    try testing.expectEqualStrings("later", (try store.get(key(0), &fresh)).?);
    try store.close();
}

fn closeStore(store: *db.Store, done: *std.atomic.Value(bool), result: *?anyerror) void {
    store.close() catch |err| {
        result.* = err;
    };
    done.store(true, .release);
}

test "close waits for a pinned reader to finish its physical read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "old")}));

    var faults: db.storage.Faults = .{};
    support.inject(&faults);
    defer support.clearFaults();
    faults.armed.store(true, .release);
    var output: [16]u8 = undefined;
    var result: ReadOutcome = .{};
    const reader = try std.Thread.spawn(.{}, concurrentRead, .{ &store, key(0), &output, &result });
    faults.waitPaused();

    var closed: std.atomic.Value(bool) = .init(false);
    var close_result: ?anyerror = null;
    const closer = try std.Thread.spawn(.{}, closeStore, .{ &store, &closed, &close_result });
    var probe: [16]u8 = undefined;
    while (true) {
        _ = store.get(key(0), &probe) catch |err| {
            try testing.expectEqual(error.Closed, err);
            break;
        };
        std.Thread.yield() catch {};
    }
    try testing.expect(!closed.load(.acquire));
    faults.released.store(true, .release);
    reader.join();
    closer.join();
    try testing.expectEqual(null, result.err);
    try testing.expectEqualStrings("old", output[0..result.len.?]);
    try testing.expectEqual(null, close_result);
}

test "keys from other regions never alias this region's entries" {
    var cache = try db.cache.Cache.init(testing.allocator, .{ .bytes = 4096, .shards = 1 });
    defer cache.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .cache = &cache });
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "mine")}));
    var output: [16]u8 = undefined;
    try testing.expectEqualStrings("mine", (try store.get(key(0), &output)).?);

    const aliases = [_]db.Key{
        .{ .dimension = 0, .chunk_x = 32, .chunk_z = 0, .component = .version },
        .{ .dimension = 0, .chunk_x = -32, .chunk_z = 0, .component = .version },
        .{ .dimension = 1, .chunk_x = 0, .chunk_z = 0, .component = .version },
        .{ .dimension = 0, .chunk_x = 0, .chunk_z = 32, .component = .version },
        .{ .dimension = 0, .chunk_x = 32, .chunk_z = 32, .component = .version },
    };
    for (aliases) |alias| {
        cache.put(io, alias, 1, "theirs");
        try testing.expectError(error.RegionMismatch, store.get(alias, &output));
        var required: usize = 0;
        try testing.expectError(error.RegionMismatch, store.getSized(alias, &output, &required));
        try testing.expectEqual(@as(usize, 0), required);
        try testing.expectError(error.RegionMismatch, store.valueSize(alias));
        var results: [2]db.ReadResult = undefined;
        try testing.expectError(error.RegionMismatch, store.getMany(&.{ .{ .key = key(0), .output = &output }, .{ .key = alias, .output = &output } }, &results));
        try testing.expectError(error.RegionMismatch, store.write(batch(2, &.{.{ .key = alias, .value = "mine" }})));
    }
    try testing.expectEqual(@as(?u32, 4), try store.valueSize(key(0)));
    try store.close();
}

test "getMany matches single gets across fragmented saves and reads fewer times" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .max_segment_size = 8192, .batch_buffer_size = 4096, .stats = &stats });
    defer store.deinit();
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var values: [200][4][64]u8 = undefined;
    for (&values, 1..) |*batch_values, id| {
        var entries: [4]db.Entry = undefined;
        const count = random.intRangeAtMost(usize, 1, entries.len);
        for (entries[0..count], batch_values[0..count]) |*entry, *bytes| {
            const len = random.uintLessThan(usize, bytes.len);
            random.bytes(bytes[0..len]);
            entry.* = put(random.uintLessThan(u8, 24), if (random.uintLessThan(u8, 8) == 0) null else bytes[0..len]);
        }
        _ = try store.write(batch(id, entries[0..count]));
    }

    var outputs: [40][64]u8 = undefined;
    var requests: [40]db.ReadRequest = undefined;
    var results: [40]db.ReadResult = undefined;
    for (&requests, &outputs) |*request, *output| {
        request.* = .{ .key = key(random.uintLessThan(u8, 24)), .output = output[0..random.uintAtMost(usize, output.len)] };
    }
    stats.reset();
    try store.getMany(&requests, &results);
    try testing.expect(stats.disk_reads.load(.monotonic) < requests.len);
    for (requests, results) |request, result| {
        var single: [64]u8 = undefined;
        var required: usize = 0;
        const value = store.getSized(request.key, single[0..request.output.len], &required) catch |err| {
            try testing.expectEqual(error.BufferTooSmall, err);
            try testing.expectEqual(db.ReadStatus.buffer_too_small, result.status);
            try testing.expectEqual(required, result.required);
            continue;
        };
        if (value) |bytes| {
            try testing.expectEqual(db.ReadStatus.ok, result.status);
            try testing.expectEqualSlices(u8, bytes, result.value);
        } else try testing.expectEqual(db.ReadStatus.not_found, result.status);
    }
    try store.close();
}

test "getMany still detects a corrupt record inside a combined read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    _ = try store.write(batch(1, &.{ put(0, "aaaa"), put(1, "bbbb"), put(2, "cccc") }));
    const file = try support.openFile(tmp.dir, segment_name);
    defer file.handle.close(io);
    // The second record's value.
    try file.writeAll("x", db.segment.encoded_len + db.frame.header_len + (db.record.overhead + 4) + db.record.header_len);

    var out: [3][4]u8 = undefined;
    var results: [3]db.ReadResult = undefined;
    try testing.expectError(error.ChecksumMismatch, store.getMany(&.{
        .{ .key = key(0), .output = &out[0] },
        .{ .key = key(1), .output = &out[1] },
        .{ .key = key(2), .output = &out[2] },
    }, &results));
    try testing.expectEqualStrings("aaaa", (try store.get(key(0), &out[0])).?);
}

test "values above the threshold are compressed and read back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats, .compression_threshold = 64 });
    defer store.deinit();
    var repetitive: [4096]u8 = undefined;
    for (&repetitive, 0..) |*b, i| b.* = @truncate(i / 64);
    var noise: [300]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(&noise);
    _ = try store.write(batch(1, &.{ put(0, &repetitive), put(1, &noise), put(2, "short") }));
    try testing.expect(stats.compressed_bytes_written.load(.monotonic) < stats.raw_bytes_written.load(.monotonic) / 4);
    try store.close();

    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    var output: [4096]u8 = undefined;
    try testing.expectEqualSlices(u8, &repetitive, (try reopened.get(key(0), &output)).?);
    try testing.expectEqualSlices(u8, &noise, (try reopened.get(key(1), &output)).?);
    try testing.expectEqualStrings("short", (try reopened.get(key(2), &output)).?);
    try reopened.close();
}

const SyncWriter = struct {
    store: *db.Store,
    x: i32,
    last_ok: u64 = 0,
    failure: ?anyerror = null,
    const rounds = 50;

    fn run(self: *SyncWriter) void {
        for (1..rounds + 1) |round| {
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, round, .little);
            const result = self.store.write(batch(0, &.{put(self.x, &value)})) catch |err| {
                self.failure = err;
                return;
            };
            if (!result.synced) self.failure = error.BadResult;
            self.last_ok = round;
        }
    }
};

test "concurrent sync writers share fsyncs and every acknowledged write survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    const options: db.store.Options = .{ .durability = .sync, .stats = &stats };
    var writers: [8]SyncWriter = undefined;
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, options);
        defer store.deinit();
        var handles: [8]std.Thread = undefined;
        for (&writers, &handles, 0..) |*writer, *handle, i| {
            writer.* = .{ .store = &store, .x = @intCast(i) };
            handle.* = try std.Thread.spawn(.{}, SyncWriter.run, .{writer});
        }
        for (handles) |handle| handle.join();
        try store.close();
    }
    try testing.expectEqual(@as(u64, 8 * SyncWriter.rounds), stats.writes.load(.monotonic));
    try testing.expect(stats.fsync_count.load(.monotonic) < 8 * SyncWriter.rounds);

    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    var output: [8]u8 = undefined;
    for (writers) |writer| {
        try testing.expectEqual(null, writer.failure);
        try testing.expectEqual(@as(u64, SyncWriter.rounds), writer.last_ok);
        const value = (try store.get(key(writer.x), &output)).?;
        try testing.expectEqual(writer.last_ok, std.mem.readInt(u64, value[0..8], .little));
    }
    try store.close();
}

test "groups are durable save barriers and rotate as one unit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    const value = "0123456789012345678901234567890123456789";
    const one = try (batch(1, &.{put(0, value)})).validate();
    const options: db.store.Options = .{
        .batch_buffer_size = one * 4,
        .max_segment_size = db.segment.encoded_len + one * 5,
        .stats = &stats,
    };
    var values: [8][40]u8 = undefined;
    var entries: [8][1]db.Entry = undefined;
    var batches: [8]db.WriteBatch = undefined;
    for (&values, &entries, &batches, 0..) |*bytes, *batch_entries, *b, i| {
        bytes.* = value.*;
        bytes[0] = @intCast('a' + i);
        batch_entries.* = .{put(@intCast(i % 3), bytes)};
        b.* = batch(i + 1, batch_entries);
    }
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, options);
        defer store.deinit();
        try testing.expectError(error.BufferTooSmall, store.writeGroup(&batches));
        const first = try store.writeGroup(batches[0..4]);
        try testing.expect(first.synced);
        try testing.expectEqual(store.offset, store.synced_offset);
        _ = try store.writeGroup(batches[4..8]);
        try testing.expectEqual(@as(usize, 2), store.generation.count);
        try store.close();
    }
    try testing.expectEqual(@as(u64, 8), stats.writes.load(.monotonic));
    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    try testing.expectEqual(@as(u64, 8), try store.lastBatchId());
    var output: [40]u8 = undefined;
    for (5..8) |i| try testing.expectEqualStrings(&values[i], (try store.get(key(@intCast(i % 3)), &output)).?);
    try store.close();
}

test "a group with one invalid batch writes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{});
    defer store.deinit();
    const bad: db.Entry = .{ .key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .version, .subchunk_y = 3 }, .value = "x" };
    try testing.expectError(error.InvalidSubchunkY, store.writeGroup(&.{ batch(1, &.{put(0, "fine")}), batch(2, &.{bad}) }));
    try testing.expectEqual(@as(u64, 0), try store.lastBatchId());
    var output: [8]u8 = undefined;
    try testing.expectEqual(null, try store.get(key(0), &output));
    _ = try store.writeGroup(&.{batch(1, &.{put(0, "fine")})});
    try testing.expectEqualStrings("fine", (try store.get(key(0), &output)).?);
    try store.close();
}

test "skip_unchanged drops no-op puts and deletes but keeps every real change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    const options: db.store.Options = .{ .stats = &stats, .skip_unchanged = true };
    var output: [512]u8 = undefined;
    var long: [400]u8 = @splat('L');
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, options);
        defer store.deinit();
        _ = try store.write(batch(1, &.{ put(0, "same"), put(1, "other"), put(2, &long) }));

        const skipped = try store.write(batch(2, &.{ put(0, "same"), put(2, &long) }));
        try testing.expectEqual(skipped.start, skipped.end);
        try testing.expectEqual(@as(u64, 1), try store.lastBatchId());
        _ = try store.write(batch(3, &.{put(5, null)}));
        try testing.expectEqual(@as(u64, 3), stats.unchanged_write_skips.load(.monotonic));
        try testing.expectEqual(@as(u64, 1), stats.writes.load(.monotonic));

        _ = try store.write(batch(4, &.{ put(0, "same"), put(1, "diff!") }));
        try testing.expectEqual(@as(u64, 4), stats.records_written.load(.monotonic));
        try testing.expectEqualStrings("diff!", (try store.get(key(1), &output)).?);

        // Same length, different bytes.
        _ = try store.write(batch(5, &.{put(0, "SAME")}));
        try testing.expectEqualStrings("SAME", (try store.get(key(0), &output)).?);

        // The last occurrence wins inside a batch.
        _ = try store.write(batch(6, &.{ put(1, "changed"), put(1, "diff!") }));
        try testing.expectEqualStrings("diff!", (try store.get(key(1), &output)).?);

        _ = try store.write(batch(7, &.{put(1, null)}));
        try testing.expectEqual(null, try store.get(key(1), &output));
        try store.close();
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    const skips = stats.unchanged_write_skips.load(.monotonic);
    const skipped = try store.write(batch(8, &.{ put(0, "SAME"), put(2, &long) }));
    try testing.expectEqual(skipped.start, skipped.end);
    try testing.expectEqual(skips + 2, stats.unchanged_write_skips.load(.monotonic));
    try store.close();
}

test "stats count gets, writes, bytes and real reads only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var stats: db.Stats = .{};
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, .{ .stats = &stats, .durability = .sync });
    defer store.deinit();
    _ = try store.write(batch(1, &.{ put(0, "abc"), put(1, "defgh") }));
    try testing.expectEqual(@as(u64, 1), stats.writes.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), stats.records_written.load(.monotonic));
    try testing.expectEqual(@as(u64, 8), stats.raw_bytes_written.load(.monotonic));
    try testing.expectEqual(@as(u64, 8), stats.compressed_bytes_written.load(.monotonic));
    try testing.expect(stats.fsync_count.load(.monotonic) >= 1);

    var output: [128]u8 = undefined;
    var required: usize = 0;
    try testing.expectEqual(@as(u64, 0), stats.disk_reads.load(.monotonic));
    try testing.expectEqual(null, try store.get(key(5), &output));
    try testing.expectEqual(@as(u64, 0), stats.disk_reads.load(.monotonic));
    _ = try store.get(key(0), &output);
    _ = try store.getSized(key(1), &output, &required);
    try testing.expectEqual(@as(u64, 3), stats.get_calls.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), stats.disk_reads.load(.monotonic));
    try store.close();
}

const Hammer = struct {
    store: *db.Store,
    x: i32,
    rounds: usize,
    ids: []u64,
    failure: ?anyerror = null,

    fn run(self: *Hammer) void {
        for (0..self.rounds) |round| {
            var value: [24]u8 = undefined;
            std.mem.writeInt(u64, value[0..8], round, .little);
            @memset(value[8..], @truncate(round));
            const entries = [_]db.Entry{ put(self.x, &value), put(self.x + 16, if (round % 5 == 0) null else &value) };
            const result = self.store.write(batch(0, &entries)) catch |err| {
                self.failure = err;
                return;
            };
            self.ids[round] = result.batch_id;
        }
    }
};

fn collide(store: *db.Store, failures: *std.atomic.Value(usize)) void {
    // Losers must get BatchOrder.
    for (0..200) |i| {
        _ = store.write(batch(1_000_000 + i * 3, &.{put(31, "explicit")})) catch |err| {
            if (err != error.BatchOrder) _ = failures.fetchAdd(1000, .monotonic) else _ = failures.fetchAdd(1, .monotonic);
        };
    }
}

test "many writers in one region get unique IDs and every acknowledged write survives" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const threads = 12;
    const rounds = 400;
    var ids: [threads][rounds]u64 = undefined;
    var hammers: [threads]Hammer = undefined;
    var collisions: std.atomic.Value(usize) = .init(0);
    const options: db.store.Options = .{ .max_segment_size = 64 * 1024, .max_segments = 255, .batch_buffer_size = 4096 };
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, options);
        defer store.deinit();
        var handles: [threads + 1]std.Thread = undefined;
        for (&hammers, handles[0..threads], 0..) |*h, *handle, i| {
            h.* = .{ .store = &store, .x = @intCast(i), .rounds = rounds, .ids = &ids[i] };
            handle.* = try std.Thread.spawn(.{}, Hammer.run, .{h});
        }
        handles[threads] = try std.Thread.spawn(.{}, collide, .{ &store, &collisions });
        for (handles) |handle| handle.join();
        try testing.expect(collisions.load(.monotonic) < 1000);
        for (hammers) |h| try testing.expectEqual(null, h.failure);
        try store.close();
    }
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (ids) |list| {
        for (list[1..], list[0 .. rounds - 1]) |later, earlier| try testing.expect(later > earlier);
        for (list) |id| try testing.expect(!(try seen.getOrPut(testing.allocator, id)).found_existing);
    }
    var store = try db.Store.open(testing.allocator, io, tmp.dir, options);
    defer store.deinit();
    var output: [24]u8 = undefined;
    for (0..threads) |i| {
        const value = (try store.get(key(@intCast(i)), &output)).?;
        try testing.expectEqual(@as(u64, rounds - 1), std.mem.readInt(u64, value[0..8], .little));
        try testing.expectEqualStrings(value, (try store.get(key(@intCast(i + 16)), &output)).?);
    }
    try store.close();
}
