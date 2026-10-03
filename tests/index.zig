const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const Index = db.index.Index;
const region: db.Region = .{ .dimension = 0, .x = 0, .z = 0 };
const salt = 9;

const Change = struct { x: u5 = 0, z: u5 = 0, component: db.Component = .version, y: i8 = 0, value: ?[]const u8 };

/// Encodes one frame at `offset` and returns it as a scanned batch.
fn frameOf(buffer: []u8, id: u64, offset: u64, changes: []const Change) !db.recovery.Batch {
    var builder: db.frame.Builder = .init(buffer);
    for (changes) |c| try builder.add(@as(u10, c.z) * 32 + c.x, db.key.localKey(c.component, c.y), c.value, null, 0);
    const bytes = builder.finish(.batch, id, salt);
    return .{ .header = try db.frame.Header.read(bytes[0..db.frame.header_len], salt), .bytes = bytes, .offset = offset };
}

fn lookup(index: *const Index, x: u5, component: db.Component, y: i8) ?db.index.Location {
    return index.lookup(x, db.key.localKey(component, y));
}

test "the last change for each key wins, within and across frames" {
    var index = try Index.init(testing.allocator, region, 1, 100);
    defer index.deinit();
    var buffer: [1024]u8 = undefined;
    try index.apply(try frameOf(&buffer, 1, 48, &.{ .{ .value = "a" }, .{ .x = 1, .value = "b" }, .{ .value = "c" } }), 0);
    try testing.expectEqual(@as(u32, 2), index.count);
    const first = lookup(&index, 0, .version, 0).?;
    try testing.expectEqual(@as(u32, 1), first.stored_len);
    try testing.expectEqual(@as(u64, 1), first.batch_id);
    // The third record, not the first, is live.
    try testing.expectEqual(@as(u32, 48 + db.frame.header_len + 2 * (db.record.overhead + 1)), first.offset);

    try index.apply(try frameOf(&buffer, 2, 200, &.{ .{ .x = 1, .value = null }, .{ .value = "longer" } }), 0);
    try testing.expectEqual(@as(u32, 1), index.count);
    try testing.expectEqual(@as(?db.index.Location, null), lookup(&index, 1, .version, 0));
    try testing.expectEqual(@as(u32, 6), lookup(&index, 0, .version, 0).?.raw_len);
    try testing.expectEqual(@as(u64, 2), index.lastBatchId());
    try testing.expectEqual(@as(u64, db.record.overhead + 6), index.live_bytes);

    try testing.expectError(error.BatchOrder, index.apply(try frameOf(&buffer, 2, 300, &.{.{ .value = "x" }}), 0));
}

test "the key limit counts net additions and leaves the index untouched when exceeded" {
    var index = try Index.init(testing.allocator, region, 1, 2);
    defer index.deinit();
    var buffer: [1024]u8 = undefined;
    try index.apply(try frameOf(&buffer, 1, 48, &.{ .{ .value = "a" }, .{ .x = 1, .value = "b" } }), 0);
    try testing.expectError(error.IndexFull, index.prepare(&.{try frameOf(&buffer, 2, 100, &.{.{ .x = 2, .value = "c" }})}, 0));
    try testing.expectEqual(@as(u32, 2), index.count);
    try testing.expectEqual(@as(u64, 1), index.lastBatchId());
    // Replacing and swapping keys at the limit is fine.
    try index.apply(try frameOf(&buffer, 2, 100, &.{ .{ .x = 1, .value = null }, .{ .x = 2, .value = "c" }, .{ .value = "d" } }), 0);
    try testing.expectEqual(@as(u32, 2), index.count);
}

test "subchunk Y and components never collide, and keys come back sorted" {
    var index = try Index.init(testing.allocator, region, 1, 100);
    defer index.deinit();
    var buffer: [2048]u8 = undefined;
    try index.apply(try frameOf(&buffer, 1, 48, &.{
        .{ .component = .subchunk, .y = 1, .value = "+1" },
        .{ .component = .subchunk, .y = -1, .value = "-1" },
        .{ .component = .subchunk, .y = -128, .value = "low" },
        .{ .component = .subchunk, .y = 127, .value = "high" },
        .{ .component = .data3d, .value = "d" },
        .{ .component = @enumFromInt(0xfe), .value = "unknown" },
    }), 0);
    try testing.expectEqual(@as(u32, 6), index.count);
    for ([_]i8{ 1, -1, -128, 127 }) |y| try testing.expect(lookup(&index, 0, .subchunk, y) != null);
    try testing.expectEqual(@as(?db.index.Location, null), lookup(&index, 0, .subchunk, 0));

    var list: std.ArrayListUnmanaged(db.Key) = .empty;
    defer list.deinit(testing.allocator);
    try index.appendKeys(testing.allocator, .{}, &list);
    const ys = [_]i32{ -128, -1, 1, 127 };
    try testing.expectEqual(db.Component.data3d, list.items[0].component);
    for (list.items[1..5], ys) |k, y| try testing.expectEqual(y, k.subchunk_y);
    try testing.expectEqual(@as(u8, 0xfe), @intFromEnum(list.items[5].component));
}

test "negative regions map chunks to slots 0..1023" {
    const negative: db.Region = .{ .dimension = -1, .x = -3, .z = -1 };
    var index = try Index.init(testing.allocator, negative, 1, 10);
    defer index.deinit();
    const key: db.Key = .{ .dimension = -1, .chunk_x = -96, .chunk_z = -1, .component = .version };
    try testing.expectEqual(negative, key.region());
    try testing.expectEqual(@as(u10, 31 * 32), key.slot());
    var buffer: [256]u8 = undefined;
    try index.apply(try frameOf(&buffer, 1, 48, &.{.{ .x = 0, .z = 31, .value = "corner" }}), 0);
    try testing.expect((try index.get(key)) != null);
    try testing.expectError(error.RegionMismatch, index.get(.{ .dimension = -1, .chunk_x = -96 + 32, .chunk_z = -1, .component = .version }));
}

test "preparing several frames at once matches applying them one by one" {
    var together = try Index.init(testing.allocator, region, 1, 100);
    defer together.deinit();
    var apart = try Index.init(testing.allocator, region, 1, 100);
    defer apart.deinit();
    var buffers: [3][512]u8 = undefined;
    const frames = [_]db.recovery.Batch{
        try frameOf(&buffers[0], 1, 48, &.{ .{ .value = "a" }, .{ .x = 1, .value = "b" } }),
        try frameOf(&buffers[1], 2, 148, &.{ .{ .value = null }, .{ .x = 2, .value = "c" } }),
        try frameOf(&buffers[2], 5, 248, &.{ .{ .value = "d" }, .{ .x = 2, .value = null } }),
    };
    together.publish(try together.prepare(&frames, 0));
    for (frames) |f| try apart.apply(f, 0);
    try testing.expectEqual(apart.count, together.count);
    try testing.expectEqual(apart.lastBatchId(), together.lastBatchId());
    try testing.expectEqual(apart.live_bytes, together.live_bytes);
    try testing.expectEqual(apart.total_bytes, together.total_bytes);
    for (0..3) |x| try testing.expectEqual(lookup(&apart, @intCast(x), .version, 0), lookup(&together, @intCast(x), .version, 0));
}

fn prepareWithAllocator(allocator: std.mem.Allocator) !void {
    var index = try Index.init(allocator, region, 1, 1000);
    defer index.deinit();
    var buffer: [8192]u8 = undefined;
    var changes: [100]Change = undefined;
    for (&changes, 0..) |*c, i| c.* = .{ .x = @intCast(i % 32), .component = .subchunk, .y = @intCast(i / 32), .value = "v" };
    const before = index.count;
    const prepared = index.prepare(&.{try frameOf(&buffer, 1, 48, &changes)}, 0) catch |err| {
        try testing.expectEqual(before, index.count);
        return err;
    };
    index.publish(prepared);
    try testing.expectEqual(@as(u32, 100), index.count);
}

test "allocation failures during prepare leave no leaks and no partial publication" {
    try testing.checkAllAllocationFailures(testing.allocator, prepareWithAllocator, .{});
}

test "random updates match a reference map" {
    var index = try Index.init(testing.allocator, region, 1, 4096);
    defer index.deinit();
    var reference: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer reference.deinit(testing.allocator);
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 48;
    for (1..400) |id| {
        var changes: [24]Change = undefined;
        const count = random.intRangeAtMost(usize, 1, changes.len);
        var values: [24][4]u8 = undefined;
        for (changes[0..count], values[0..count]) |*c, *v| {
            const slot: u10 = @intCast(random.uintLessThan(u16, 1024));
            const y = random.intRangeAtMost(i8, -4, 4);
            const len = random.uintAtMost(usize, 4);
            c.* = .{ .x = @truncate(slot), .z = @truncate(slot >> 5), .component = .subchunk, .y = y, .value = if (random.uintLessThan(u8, 5) == 0) null else v[0..len] };
            const ref_key = @as(u32, slot) << 16 | db.key.localKey(.subchunk, y);
            if (c.value) |value| try reference.put(testing.allocator, ref_key, @intCast(value.len)) else _ = reference.remove(ref_key);
        }
        const frame = try frameOf(&buffer, id, offset, changes[0..count]);
        try index.apply(frame, 0);
        offset += frame.bytes.len;
    }
    try testing.expectEqual(reference.count(), index.count);
    var iterator = reference.iterator();
    while (iterator.next()) |entry| {
        const location = index.lookup(@intCast(entry.key_ptr.* >> 16), @truncate(entry.key_ptr.*)).?;
        try testing.expectEqual(entry.value_ptr.*, location.raw_len);
    }
    var entries: [64]db.index.Entry = undefined;
    var total: usize = 0;
    for (0..1024) |slot| {
        const n = index.chunkEntries(@intCast(slot), &entries);
        for (entries[0..n], 0..) |entry, i| if (i > 0) try testing.expect(entries[i - 1].local < entry.local);
        total += n;
    }
    try testing.expectEqual(index.count, @as(u32, @intCast(total)));
}
