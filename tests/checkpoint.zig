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

test "checkpoint loading fits a small region in a bounded allocator" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    var buffer: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var store = try db.Store.open(fixed.allocator(), io, tmp.dir, .{});
    defer store.deinit();
    try testing.expect(store.checkpointed.offset != 0);
    try expectPopulated(&store);
    try store.close();
}

test "checkpoint entries reject truncated bytes and invalid component keys" {
    var bytes: [db.checkpoint.entry_len]u8 = undefined;
    const location: db.index.Location = .{ .batch_id = 1, .offset = 48, .stored_len = 1, .raw_len = 1, .fingerprint = 0, .segment = 0, .compression = .none };
    db.checkpoint.writeEntry(&bytes, 0x2c80, location, false);
    for (0..bytes.len) |len| try testing.expectError(error.InvalidLength, db.checkpoint.readEntry(bytes[0..len], false));
    try testing.expectError(error.InvalidLength, db.checkpoint.readEntry(&bytes, true));
    bytes[0] = 0;
    try testing.expectError(error.InvalidFlags, db.checkpoint.readEntry(&bytes, false));
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
    const cut = try support.segmentLength(tmp.dir);
    // The clean close synced those bytes, so this is lost data and not a write a crash cut short.
    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, .{}));
    try testing.expectEqual(cut, try support.segmentLength(tmp.dir));

    // Without the checkpoint nothing tells it from a torn write, which open drops.
    try tmp.dir.deleteFile(io, "INDEX");
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer store.deinit();
    try testing.expectEqual(@as(u64, 39), try store.lastBatchId());
    var output: [64]u8 = undefined;
    try testing.expectEqual(@as(u8, 38), (try store.get(key(18), &output)).?[0]);
    try testing.expectEqual(@as(u8, 19), (try store.get(key(19), &output)).?[0]);
    try testing.expect(try support.segmentLength(tmp.dir) < cut);
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

    var stats: db.Stats = .{};
    var skipping = try db.Store.open(testing.allocator, io, tmp.dir, .{ .skip_unchanged = true, .stats = &stats });
    defer skipping.deinit();
    var same: [64]u8 = @splat(39);
    const result = try skipping.write(batch(0, &.{put(19, &same)}));
    try testing.expectEqual(result.start, result.end);
    try testing.expectEqual(@as(u64, 1), stats.unchanged_write_skips.load(.monotonic));
    try skipping.close();
}

test "skip_unchanged reuses a checkpoint written without fingerprints and still compares every candidate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});

    var stats: db.Stats = .{};
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{ .skip_unchanged = true, .stats = &stats });
    defer store.deinit();
    try testing.expectEqual(store.generation.count, store.checkpointed.segments);
    try testing.expect(store.checkpointed.offset != 0);
    try expectPopulated(&store);

    var same: [64]u8 = @splat(39);
    const skipped = try store.write(batch(0, &.{put(19, &same)}));
    try testing.expectEqual(skipped.start, skipped.end);
    try testing.expectEqual(@as(u64, 1), stats.unchanged_write_skips.load(.monotonic));

    // same length and compression, so only the byte comparison can tell it changed
    var changed = same;
    changed[63] = 0;
    const written = try store.write(batch(0, &.{put(19, &changed)}));
    try testing.expect(written.end > written.start);
    try testing.expectEqual(@as(u64, 1), stats.unchanged_write_skips.load(.monotonic));
    try store.close();

    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{ .skip_unchanged = true });
    defer reopened.deinit();
    var output: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &changed, (try reopened.get(key(19), &output)).?);
    try reopened.close();
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

test "a leftover INDEX.tmp from a crash is ignored and replaced" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "INDEX.tmp", .data = "half written" });
    var store = try db.Store.open(testing.allocator, io, tmp.dir, .{});
    defer store.deinit();
    try expectPopulated(&store);
    _ = try store.write(batch(0, &.{put(2, "x")}));
    try store.close();
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "INDEX.tmp", .{}));
    var scratch: [4096]u8 = undefined;
    var orphans: [4]db.inspection.Orphan = undefined;
    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(@as(usize, 0), report.unknown_entries);
}

test "a clean checkpoint cannot hide damaged or foreign segment headers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try populate(tmp.dir, .{});
    const file = try support.openFile(tmp.dir, support.segment_name);
    defer file.handle.close(io);
    var original: [db.segment.encoded_len]u8 = undefined;
    try file.readExact(&original, 0);
    var header = try db.segment.Header.decode(&original);
    header.salt ^= 2;
    try file.writeAll(&(try header.encode()), 0);
    try testing.expectError(error.IdentityMismatch, db.Store.open(testing.allocator, io, tmp.dir, .{}));
    original[0] ^= 1;
    try file.writeAll(&original, 0);
    try testing.expectError(error.InvalidMagic, db.Store.open(testing.allocator, io, tmp.dir, .{}));
}

test "checkpoint headers mark fingerprints of uncompressed values apart from 1.2's" {
    const header: db.checkpoint.Header = .{ .fingerprints = true, .generation = 1, .salt = 2, .segments = 1, .entries = 0, .offset = 48, .last_batch_id = 0, .total_bytes = 0, .seen_batch = false };
    var bytes: [db.checkpoint.header_len]u8 = undefined;
    header.write(&bytes);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[6..8], .little));
    const raw = try db.checkpoint.Header.read(&bytes);
    try testing.expect(raw.fingerprints and !raw.stored_fingerprints);

    for ([_]u16{ 0, 1, 3 }) |flags| {
        std.mem.writeInt(u16, bytes[6..8], flags, .little);
        std.mem.writeInt(u32, bytes[60..64], db.crc.hash(bytes[0..60]), .little);
        if (flags == 3) {
            try testing.expectError(error.InvalidFlags, db.checkpoint.Header.read(&bytes));
        } else {
            const read = try db.checkpoint.Header.read(&bytes);
            try testing.expectEqual(flags != 0, read.fingerprints);
            try testing.expectEqual(flags == 1, read.stored_fingerprints);
        }
    }
}
