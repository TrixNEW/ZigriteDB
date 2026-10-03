const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/region.zig");
const key = support.key;
const put = support.put;
const batch = support.batch;

fn keyAt(dimension: i32, x: i32, z: i32) db.Key {
    return .{ .dimension = dimension, .chunk_x = x, .chunk_z = z, .component = .version };
}

test "world routes regions and dimensions through a bounded cache" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_regions = 1 });
    defer world.deinit();
    try testing.expectError(error.DirectoryBusy, db.World.open(testing.allocator, io, tmp.dir, .{}));
    const entries = [_]db.Entry{
        .{ .key = keyAt(0, -1, -33), .value = "negative" },
        .{ .key = keyAt(0, 32, 0), .value = "overworld" },
        .{ .key = keyAt(1, 32, 0), .value = "nether" },
    };
    for (entries) |entry| {
        _ = try world.write(batch(1, &.{entry}));
        try testing.expectEqual(@as(usize, 1), world.count);
    }
    var output: [128]u8 = undefined;
    for (entries) |entry| try testing.expectEqualStrings(entry.value.?, (try world.get(entry.key, &output)).?);
    try testing.expectError(error.BatchOrder, world.write(batch(1, &.{entries[0]})));
    try testing.expectEqual(@as(u64, 2), (try world.compact(entries[0].key.region())).?.generation);
    try world.close();

    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_regions = 1 });
    defer reopened.deinit();
    for (entries) |entry| try testing.expectEqualStrings(entry.value.?, (try reopened.get(entry.key, &output)).?);
    _ = try reopened.write(batch(2, &.{.{ .key = entries[0].key, .value = null }}));
    try testing.expectEqual(null, try reopened.get(entries[0].key, &output));
    try reopened.flush();
    try reopened.close();
    try testing.expectError(error.Closed, reopened.get(entries[0].key, &output));
}

test "a region remembered as missing is readable right after a write creates it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_regions = 1 });
    defer world.deinit();
    var output: [16]u8 = undefined;
    for (0..2) |_| try testing.expectEqual(null, try world.get(key(64), &output));
    _ = try world.write(batch(1, &.{put(64, "saved")}));
    _ = try world.write(batch(1, &.{put(0, "other")}));
    try testing.expectEqualStrings("saved", (try world.get(key(64), &output)).?);
    try world.close();
}

test "getMany takes more keys in one region than a store batch holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    for (0..32) |x| _ = try world.write(batch(x + 1, &.{put(@intCast(x), "v")}));

    var outputs: [256][4]u8 = undefined;
    var requests: [256]db.ReadRequest = undefined;
    var results: [256]db.ReadResult = undefined;
    for (&requests, &outputs, 0..) |*request, *output, i| {
        request.* = .{ .key = keyAt(0, @intCast(i % 32), @intCast(i / 32)), .output = output };
    }
    try world.getMany(&requests, &results);
    for (results, 0..) |result, i| try testing.expectEqual(if (i < 32) db.ReadStatus.ok else db.ReadStatus.not_found, result.status);
    try world.close();
}

test "getChunk reads a whole chunk and reports missing chunks as empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    const at = struct {
        fn entry(component: db.Component, y: i32, value: []const u8) db.Entry {
            return .{ .key = .{ .dimension = 2, .chunk_x = -40, .chunk_z = 7, .component = component, .subchunk_y = y }, .value = value };
        }
    }.entry;
    _ = try world.write(batch(0, &.{ at(.subchunk, 0, "s0"), at(.version, 0, "v"), at(.subchunk, -1, "sm1") }));
    var buffer: [64]u8 = undefined;
    var records: [8]db.ChunkRecord = undefined;
    var result: db.ChunkResult = undefined;
    try world.getChunk(2, -40, 7, &buffer, &records, &result);
    try testing.expectEqual(@as(usize, 3), result.count);
    try testing.expectEqualStrings("v", records[0].value);
    try testing.expectEqual(@as(i8, -1), records[1].subchunk_y);
    try testing.expectEqualStrings("s0", records[2].value);
    try world.getChunk(2, -41, 7, &buffer, &records, &result);
    try testing.expectEqual(@as(usize, 0), result.count);
    try world.getChunk(3, -40, 7, &buffer, &records, &result);
    try testing.expectEqual(@as(usize, 0), result.count);
    try world.close();
}

test "missing reads and rejected batches create no region files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqual(null, try world.get(key(0), &output));
    try testing.expectEqual(null, try world.compact(key(0).region()));
    try testing.expectError(error.RegionMismatch, world.write(batch(1, &.{ put(0, "a"), put(32, "b") })));
    var iterator = world.directory.dir.iterate();
    while (try iterator.next(io)) |entry| try testing.expectEqualStrings(db.world.format_file, entry.name);
}

test "world rejects mismatched region metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
        try world.close();
    }
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
    try testing.expectError(error.RegionMismatch, world.get(key(0), &output));
}

test "worlds written before the format marker need migration" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "00000000-00000000-00000000.region", .default_dir);
    const region_dir = try tmp.dir.openDir(io, "00000000-00000000-00000000.region", .{});
    defer region_dir.close(io);
    {
        var store = try db.Store.create(testing.allocator, io, region_dir, support.region, .{});
        try store.close();
    }
    // A bare region with a current manifest, e.g. a recovered one, is adopted.
    {
        var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
        try world.close();
    }
    try tmp.dir.deleteFile(io, db.world.format_file);
    const manifest_file = try support.openFile(region_dir, "MANIFEST");
    defer manifest_file.handle.close(io);
    try manifest_file.writeAll(&.{ 1, 0 }, 4);
    try testing.expectError(error.NeedsMigration, db.World.open(testing.allocator, io, tmp.dir, .{}));

    var other = testing.tmpDir(.{});
    defer other.cleanup();
    {
        var world = try db.World.open(testing.allocator, io, other.dir, .{});
        try world.close();
    }
    const file = try support.openFile(other.dir, db.world.format_file);
    defer file.handle.close(io);
    try file.writeAll("X", 0);
    try testing.expectError(error.InvalidFormatFile, db.World.open(testing.allocator, io, other.dir, .{}));
}

test "world never follows region symlinks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    try tmp.dir.createDir(io, "elsewhere", .default_dir);
    try tmp.dir.symLink(io, "elsewhere", "00000000-00000000-00000000.region", .{});
    try testing.expectError(error.NotDir, world.write(batch(1, &.{put(0, "saved")})));
}

test "world releases its lock even when a region cannot flush" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    _ = try world.write(batch(1, &.{put(0, "saved")}));
    world.slots[0].opened.store.failed = true;
    try testing.expectError(error.WriterFailed, world.close());
    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try reopened.get(key(0), &output)).?);
}

fn worldWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(allocator, io, tmp.dir, .{ .max_open_regions = 1, .region = .{ .batch_buffer_size = 256 } });
    defer world.deinit();
    _ = try world.write(batch(1, &.{put(0, "a")}));
    _ = try world.write(batch(1, &.{put(32, "b")}));
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("a", (try world.get(key(0), &output)).?);
    try world.close();
}

test "world allocation failures release resources" {
    try testing.checkAllAllocationFailures(testing.allocator, worldWithAllocator, .{});
}

test "busy regions stay pinned while other regions write and close waits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_regions = 2 });
    defer world.deinit();
    _ = try world.write(batch(1, &.{put(0, "first")}));
    const first = &world.slots[0].opened.store;
    _ = try world.write(batch(1, &.{put(32, "second")}));

    first.table.lockUncancelable(io);
    var locked = true;
    defer if (locked) first.table.unlock(io);
    var read_result: anyerror!void = error.Unexpected;
    const reader = try std.Thread.spawn(.{}, readPinned, .{ &world, &read_result });
    var joined = false;
    defer if (!joined) reader.join();
    defer if (locked) {
        first.table.unlock(io);
        locked = false;
    };
    while (true) {
        world.mutex.lockUncancelable(io);
        var pinned = false;
        for (world.slots[0..world.count]) |slot| {
            if (&slot.opened.store == first) pinned = slot.opened.users.load(.seq_cst) != 0;
        }
        world.mutex.unlock(io);
        if (pinned) break;
        std.Thread.yield() catch {};
    }
    _ = try world.write(batch(1, &.{put(64, "third")}));
    try testing.expectEqual(@as(usize, 2), world.count);
    var output: [32]u8 = undefined;
    try testing.expectEqualStrings("third", (try world.get(key(64), &output)).?);

    var close_result: anyerror!void = error.Unexpected;
    const closer = try std.Thread.spawn(.{}, closePinned, .{ &world, &close_result });
    while (true) {
        world.mutex.lockUncancelable(io);
        const closing = world.closing;
        world.mutex.unlock(io);
        if (closing) break;
        std.Thread.yield() catch {};
    }
    const rejected = world.get(key(64), &output);
    first.table.unlock(io);
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
    try testing.expectEqualStrings("first", (try world.get(key(0), &output)).?);
}

fn closePinned(world: *db.World, result: *anyerror!void) void {
    result.* = world.close();
}

test "save groups sync buffered batches and reject mixed regions before writing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .region = .{ .durability = .buffered } });
    defer world.deinit();
    const batches = [_]db.WriteBatch{ batch(1, &.{put(0, "first")}), batch(2, &.{ put(0, "last"), put(1, "other") }) };
    try testing.expectError(error.RegionMismatch, world.writeGroup(&.{ batches[0], batch(2, &.{put(32, "wrong")}) }));
    try testing.expectEqual(@as(usize, 0), world.count);
    _ = try world.writeGroup(&batches);
    const store = &world.slots[0].opened.store;
    try testing.expectEqual(store.offset, store.synced_offset);
    try testing.expectEqual(.buffered, store.options.durability);
    try testing.expectError(error.BatchOrder, world.writeGroup(&batches));
    try world.close();
    var reopened = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer reopened.deinit();
    var output: [32]u8 = undefined;
    try testing.expectEqualStrings("last", (try reopened.get(key(0), &output)).?);
    try testing.expectEqualStrings("other", (try reopened.get(key(1), &output)).?);
}

test "region creation can retry allocation failures without losing files" {
    for (0..32) |offset| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var world = try db.World.open(failing.allocator(), io, tmp.dir, .{});
        defer world.deinit();
        failing.fail_index = failing.alloc_index + offset;
        if (world.write(batch(1, &.{put(0, "saved")}))) |_| {
            return;
        } else |err| try testing.expect(err == error.OutOfMemory);
        failing.fail_index = std.math.maxInt(usize);
        _ = try world.write(batch(1, &.{put(0, "saved")}));
        var output: [16]u8 = undefined;
        try testing.expectEqualStrings("saved", (try world.get(key(0), &output)).?);
    }
    return error.AllocationRetriesExhausted;
}

fn regionDir(tmp: std.Io.Dir) !std.Io.Dir {
    {
        var world = try db.World.open(testing.allocator, io, tmp, .{});
        try world.close();
    }
    const name = "00000000-00000000-00000000.region";
    try tmp.createDir(io, name, .default_dir);
    return tmp.openDir(io, name, .{});
}

test "missing manifests never overwrite orphaned region data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try regionDir(tmp.dir);
    defer dir.close(io);
    const file = try dir.createFile(io, "orphan", .{ .read = true, .exclusive = true });
    defer file.close(io);
    const device: db.storage.File = .{ .handle = file, .io = io };
    try device.writeAll("preserve", 0);
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    try testing.expectError(error.MissingManifest, world.write(batch(1, &.{put(0, "new")})));
    var output: [8]u8 = undefined;
    try device.readExact(&output, 0);
    try testing.expectEqualStrings("preserve", &output);
}

test "getMany across regions keeps the caller's order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .max_open_regions = 4 });
    defer world.deinit();
    const region_count = db.World.max_read_batch;
    for (0..region_count / 2) |half| {
        const r = half * 2;
        var value: [2]u8 = undefined;
        std.mem.writeInt(u16, &value, @intCast(r), .little);
        _ = try world.write(batch(1, &.{.{ .key = keyAt(0, (@as(i32, @intCast(r)) - 128) * 32, 0), .value = &value }}));
    }
    const count = region_count + 44;
    var outputs: [count][2]u8 = undefined;
    var requests: [count]db.ReadRequest = undefined;
    var results: [count]db.ReadResult = undefined;
    for (&requests, &outputs, 0..) |*request, *output, i| {
        const r = (i * 37) % region_count;
        request.* = .{ .key = keyAt(0, (@as(i32, @intCast(r)) - 128) * 32, 0), .output = if (i == 6) output[0..1] else output };
    }
    try world.getMany(&requests, &results);
    for (results, 0..) |result, i| {
        const r = (i * 37) % region_count;
        if (r % 2 == 1) {
            try testing.expectEqual(db.ReadStatus.not_found, result.status);
        } else if (i == 6) {
            try testing.expectEqual(db.ReadStatus.buffer_too_small, result.status);
            try testing.expectEqual(@as(usize, 2), result.required);
        } else {
            try testing.expectEqual(db.ReadStatus.ok, result.status);
            try testing.expectEqual(@as(u16, @intCast(r)), std.mem.readInt(u16, result.value[0..2], .little));
        }
    }
    try world.close();
}

test "a region whose creation crashed before its manifest was published is rebuilt by the next write" {
    for ([_]usize{ 0, db.segment.encoded_len }) |segment_len| {
        for ([_]bool{ false, true }) |temporary| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const dir = try regionDir(tmp.dir);
            defer dir.close(io);
            const segment_file = try dir.createFile(io, support.segment_name, .{});
            const zeros = [_]u8{0} ** db.segment.encoded_len;
            try segment_file.writePositionalAll(io, zeros[0..segment_len], 0);
            segment_file.close(io);
            if (temporary) (try dir.createFile(io, "MANIFEST.tmp", .{})).close(io);

            var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
            defer world.deinit();
            var output: [8]u8 = undefined;
            _ = try world.write(batch(1, &.{put(0, "healed")}));
            try testing.expectEqualStrings("healed", (try world.get(key(0), &output)).?);
            try world.close();
        }
    }
}

test "a region with records but no manifest is never discarded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try regionDir(tmp.dir);
    defer dir.close(io);
    const segment_file = try dir.createFile(io, support.segment_name, .{});
    const bytes = [_]u8{1} ** (db.segment.encoded_len + 1);
    try segment_file.writePositionalAll(io, &bytes, 0);
    segment_file.close(io);

    var world = try db.World.open(testing.allocator, io, tmp.dir, .{});
    defer world.deinit();
    try testing.expectError(error.MissingManifest, world.write(batch(1, &.{put(0, "no")})));
    try testing.expectEqual(@as(u64, bytes.len), (try dir.statFile(io, support.segment_name, .{})).size);
}

const Suggestions = struct {
    regions: [8]db.Region = undefined,
    count: usize = 0,

    fn submit(context: *anyopaque, region: db.Region) void {
        const self: *Suggestions = @ptrCast(@alignCast(context));
        self.regions[self.count] = region;
        self.count += 1;
    }
};

test "writes suggest compaction for regions that went stale" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var world = try db.World.open(testing.allocator, io, tmp.dir, .{ .region = .{ .compact_min_bytes = 4096 } });
    defer world.deinit();
    var suggestions: Suggestions = .{};
    world.compactor = .{ .context = &suggestions, .submit = Suggestions.submit };
    const value: [100]u8 = @splat('v');
    var id: u64 = 1;
    while (suggestions.count == 0) : (id += 1) {
        try testing.expect(id < 1000);
        _ = try world.write(batch(id, &.{put(40, &value)}));
    }
    try testing.expectEqual(@as(usize, 1), suggestions.count);
    try testing.expectEqualDeep(key(40).region(), suggestions.regions[0]);
    _ = try world.compact(suggestions.regions[0]);
    _ = try world.write(batch(id, &.{put(41, &value)}));
    try testing.expectEqual(@as(usize, 1), suggestions.count);
    try world.close();
}
