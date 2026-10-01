const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const metadata: db.manifest.Manifest = .{
    .generation = 1,
    .region = .{ .dimension = 0, .x = 0, .z = 0 },
    .segments = &.{1},
};

fn item(id: u64, x: i32, value: ?[]const u8) db.entry.Entry {
    const bytes = value orelse "";

    return .{
        .header = .{
            .kind = if (value == null) .delete else .put,
            .batch_id = id,
            .stored_len = @intCast(bytes.len),
            .raw_len = @intCast(bytes.len),
        },
        .key = .{ .dimension = 0, .chunk_x = x, .chunk_z = 0, .component = .metadata },
        .value = bytes,
    };
}

fn header(id: u64, bytes: []u8) !void {
    const encoded = try (db.segment.Header{
        .segment_id = id,
        .generation = 1,
        .region = metadata.region,
    }).encode();

    @memcpy(bytes[0..encoded.len], &encoded);
}

fn append(items: []const db.entry.Entry, bytes: []u8, offset: usize) !usize {
    return offset + (try (db.WriteBatch{ .entries = items }).encode(bytes[offset..])).len;
}

const Device = struct {
    bytes: []const u8,

    pub fn readExact(self: Device, output: []u8, offset: u64) !void {
        if (offset > self.bytes.len or output.len > self.bytes.len - offset)
            return error.UnexpectedEndOfFile;

        const start: usize = @intCast(offset);
        @memcpy(output, self.bytes[start..][0..output.len]);
    }
};

test "rebuild keeps the last change for each key" {
    var bytes: [1024]u8 = undefined;
    try header(1, &bytes);
    var end = try append(&.{ item(1, 0, "old"), item(1, 1, "gone") }, &bytes, 48);
    end = try append(&.{ item(2, 0, "new"), item(2, 1, null) }, &bytes, end);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 2);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    const key = item(1, 0, "").key;
    const value = (try index.read(key, Device{ .bytes = bytes[0..end] }, &scratch)).?;

    try testing.expectEqualStrings("new", value);
    try testing.expectEqual(@as(usize, 1), index.count());
    try testing.expectEqual(null, try index.get(item(1, 1, "").key));
    try testing.expectEqual(@as(u64, 2), index.last_batch_id);
}

test "a batch can replace keys at the index limit" {
    var bytes: [1024]u8 = undefined;
    try header(1, &bytes);
    var end = try append(&.{item(1, 0, "old")}, &bytes, 48);
    end = try append(&.{ item(2, 1, "first"), item(2, 0, null), item(2, 1, "last") }, &bytes, end);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 1);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    const value = (try index.read(item(1, 1, "").key, Device{ .bytes = bytes[0..end] }, &scratch)).?;
    try testing.expectEqualStrings("last", value);
    try testing.expectEqual(@as(usize, 1), index.count());
}

test "a partial tail leaves committed values intact" {
    var bytes: [1024]u8 = undefined;
    try header(1, &bytes);
    const committed = try append(&.{item(1, 0, "saved")}, &bytes, 48);
    const end = try append(&.{item(2, 0, "partial")}, &bytes, committed);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0 .. end - 1]}, 1);
    defer index.deinit();

    try testing.expect(index.has_tail);
    try testing.expectEqual(committed, index.active_offset);
    try testing.expectEqual(@as(u64, 1), (try index.get(item(1, 0, "").key)).?.batch_id);
}

test "rebuild follows the manifest across segments" {
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    try header(1, &first);
    try header(2, &second);
    const first_end = try append(&.{item(1, 0, "old")}, &first, 48);
    const second_end = try append(&.{item(2, 0, "new")}, &second, 48);
    var manifest = metadata;
    manifest.segments = &.{ 1, 2 };
    var index = try db.index.rebuild(testing.allocator, manifest, &.{ first[0..first_end], second[0..second_end] }, 1);
    defer index.deinit();

    try testing.expectEqual(@as(u16, 1), (try index.get(item(1, 0, "").key)).?.segment);
    try testing.expectError(error.IncompleteBatch, db.index.rebuild(
        testing.allocator,
        manifest,
        &.{ first[0 .. first_end - 1], second[0..second_end] },
        1,
    ));
}

test "failed rebuilds release the index" {
    var bytes: [512]u8 = undefined;
    try header(1, &bytes);
    const end = try append(&.{ item(1, 0, "one"), item(1, 1, "two") }, &bytes, 48);
    try testing.expectError(error.IndexFull, db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 1));

    bytes[48 + db.record.encoded_len] ^= 1;
    try testing.expectError(error.ChecksumMismatch, db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 2));
}

test "reads verify the segment and record" {
    var bytes: [512]u8 = undefined;
    try header(1, &bytes);
    const end = try append(&.{item(1, 0, "data")}, &bytes, 48);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 1);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    const key = item(1, 0, "").key;
    try testing.expectError(error.BufferTooSmall, index.read(key, Device{ .bytes = bytes[0..end] }, scratch[0..1]));
    try header(2, &bytes);
    try testing.expectError(error.IdentityMismatch, index.read(key, Device{ .bytes = bytes[0..end] }, &scratch));
    try header(1, &bytes);
    bytes[48 + db.record.encoded_len] ^= 1;
    try testing.expectError(error.ChecksumMismatch, index.read(key, Device{ .bytes = bytes[0..end] }, &scratch));
}

fn rebuildWithAllocator(allocator: std.mem.Allocator) !void {
    var bytes: [1024]u8 = undefined;
    try header(1, &bytes);
    var end = try append(&.{item(1, 0, "old")}, &bytes, 48);
    end = try append(&.{ item(2, 0, "new"), item(2, 1, "extra") }, &bytes, end);
    var index = try db.index.rebuild(allocator, metadata, &.{bytes[0..end]}, 2);
    defer index.deinit();

    try testing.expectEqual(@as(usize, 2), index.count());
}

test "allocation failures leave no leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, rebuildWithAllocator, .{});
}

test "mixed updates match a reference map" {
    var bytes: [32768]u8 = undefined;
    var expected = [_]?u8{null} ** 16;
    var random = std.Random.DefaultPrng.init(42);
    try header(1, &bytes);
    var end: usize = 48;

    for (1..101) |id| {
        const x = random.random().uintLessThan(u8, expected.len);
        const value: ?u8 = if (random.random().boolean()) @intCast(id) else null;
        var payload: [1]u8 = .{value orelse 0};
        end = try append(&.{item(id, x, if (value != null) &payload else null)}, &bytes, end);
        expected[x] = value;

        var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, expected.len);
        defer index.deinit();
        var scratch: [128]u8 = undefined;

        for (expected, 0..) |saved, coordinate| {
            const key = item(1, @intCast(coordinate), "").key;
            const actual = try index.read(key, Device{ .bytes = bytes[0..end] }, &scratch);

            if (saved) |byte| {
                try testing.expectEqualSlices(u8, &.{byte}, actual.?);
            } else {
                try testing.expectEqual(null, actual);
            }
        }
    }
}

test "read indexed data after reopening a file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected: db.segment.Header = .{
        .segment_id = 1,
        .generation = 1,
        .region = metadata.region,
    };

    {
        const handle = try tmp.dir.createFile(io, "segment", .{ .read = true, .exclusive = true });
        defer handle.close(io);
        const file: db.storage.File = .{ .handle = handle, .io = io };
        var writer = try db.segment_writer.Writer(db.storage.File).create(file, expected, 1024, 0);
        var scratch: [256]u8 = undefined;
        _ = try writer.append(.{ .entries = &.{item(1, 0, "saved")} }, &scratch, .sync);
    }

    const handle = try tmp.dir.openFile(io, "segment", .{});
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    var bytes: [1024]u8 = undefined;
    const len: usize = @intCast(try file.length());
    try file.readExact(bytes[0..len], 0);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..len]}, 1);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try index.read(item(1, 0, "").key, file, &scratch)).?);
}

test "repeated keys within one batch keep the last change" {
    var bytes: [2048]u8 = undefined;
    try header(1, &bytes);
    var end = try append(&.{item(1, 3, "seed")}, &bytes, 48);
    end = try append(&.{
        item(2, 0, "a"),  item(2, 1, "b"), item(2, 0, null),
        item(2, 2, null), item(2, 1, "c"), item(2, 2, "d"),
        item(2, 3, null), item(2, 0, "e"), item(2, 3, "f"),
        item(2, 3, null),
    }, &bytes, end);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 3);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    const device: Device = .{ .bytes = bytes[0..end] };
    try testing.expectEqual(@as(usize, 3), index.count());
    try testing.expectEqualStrings("e", (try index.read(item(1, 0, "").key, device, &scratch)).?);
    try testing.expectEqualStrings("c", (try index.read(item(1, 1, "").key, device, &scratch)).?);
    try testing.expectEqualStrings("d", (try index.read(item(1, 2, "").key, device, &scratch)).?);
    try testing.expectEqual(null, try index.get(item(1, 3, "").key));
}

test "replacement batches reuse index capacity without early publication" {
    var bytes: [4096]u8 = undefined;
    try header(1, &bytes);
    var initial: [6]db.entry.Entry = undefined;
    var replacement: [12]db.entry.Entry = undefined;
    for (0..6) |i| {
        initial[i] = item(1, @intCast(i), "old");
        replacement[i] = item(2, @intCast(i), null);
        replacement[6 + i] = item(2, @intCast(6 + i), "new");
    }
    const end = try append(&initial, &bytes, 48);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 6);
    defer index.deinit();
    const capacity = index.entries.capacity();
    const next = try append(&replacement, &bytes, end);
    const prepared = try index.prepare(.{
        .id = 2,
        .records = bytes[end .. next - db.batch.commit_len],
        .end_offset = next,
    }, 0);
    try testing.expectEqual(capacity, index.entries.capacity());
    try testing.expect((try index.get(initial[0].key)) != null);
    try testing.expectEqual(null, try index.get(replacement[6].key));
    index.publish(prepared);
    try testing.expectEqual(@as(usize, 6), index.count());
    for (0..6) |i| {
        try testing.expectEqual(null, try index.get(initial[i].key));
        try testing.expectEqual(@as(u64, 2), (try index.get(replacement[6 + i].key)).?.batch_id);
    }
}

fn subchunkItem(id: u64, x: i32, y: i32, value: ?[]const u8) db.entry.Entry {
    const bytes = value orelse "";
    return .{
        .header = .{
            .kind = if (value == null) .delete else .put,
            .batch_id = id,
            .stored_len = @intCast(bytes.len),
            .raw_len = @intCast(bytes.len),
        },
        .key = .{ .dimension = 0, .chunk_x = x, .chunk_z = 0, .component = .subchunk, .subchunk_y = y },
        .value = bytes,
    };
}

test "negative subchunk Y and other components never collide" {
    var bytes: [1024]u8 = undefined;
    try header(1, &bytes);
    const end = try append(&.{
        subchunkItem(1, 0, -4, "deep"),
        subchunkItem(1, 0, 0, "surface"),
        subchunkItem(1, 0, 19, "sky"),
        item(1, 0, "meta"),
    }, &bytes, 48);
    var index = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 4);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    const device = Device{ .bytes = bytes[0..end] };
    try testing.expectEqualStrings("deep", (try index.read(subchunkItem(1, 0, -4, "").key, device, &scratch)).?);
    try testing.expectEqualStrings("surface", (try index.read(subchunkItem(1, 0, 0, "").key, device, &scratch)).?);
    try testing.expectEqualStrings("sky", (try index.read(subchunkItem(1, 0, 19, "").key, device, &scratch)).?);
    try testing.expectEqualStrings("meta", (try index.read(item(1, 0, "").key, device, &scratch)).?);
    try testing.expectEqual(@as(usize, 4), index.count());
}

test "negative regions still pack local coordinates within 0..31" {
    const region: db.Region = .{ .dimension = 0, .x = -1, .z = -1 };
    const negative_metadata: db.manifest.Manifest = .{ .generation = 1, .region = region, .segments = &.{1} };
    var bytes: [1024]u8 = undefined;
    const encoded = try (db.segment.Header{ .segment_id = 1, .generation = 1, .region = region }).encode();
    @memcpy(bytes[0..encoded.len], &encoded);

    const corner_min = db.entry.Entry{
        .header = .{ .kind = .put, .batch_id = 1, .stored_len = 3, .raw_len = 3 },
        .key = .{ .dimension = 0, .chunk_x = -32, .chunk_z = -32, .component = .metadata },
        .value = "min",
    };
    const corner_max = db.entry.Entry{
        .header = .{ .kind = .put, .batch_id = 1, .stored_len = 3, .raw_len = 3 },
        .key = .{ .dimension = 0, .chunk_x = -1, .chunk_z = -1, .component = .metadata },
        .value = "max",
    };
    const end = try append(&.{ corner_min, corner_max }, &bytes, 48);
    var index = try db.index.rebuild(testing.allocator, negative_metadata, &.{bytes[0..end]}, 2);
    defer index.deinit();

    var scratch: [128]u8 = undefined;
    const device = Device{ .bytes = bytes[0..end] };
    try testing.expectEqualStrings("min", (try index.read(corner_min.key, device, &scratch)).?);
    try testing.expectEqualStrings("max", (try index.read(corner_max.key, device, &scratch)).?);
    try testing.expectEqual(@as(usize, 2), index.count());
}

test "prepared batches match rebuilding from their encoded bytes" {
    var bytes: [2048]u8 = undefined;
    try header(1, &bytes);
    const first = [_]db.entry.Entry{ item(1, 0, "a"), item(1, 1, "bb"), item(1, 0, "ccc") };
    const second = [_]db.entry.Entry{ item(2, 1, null), item(2, 2, "dddd") };
    var end = try append(&first, &bytes, 48);
    end = try append(&second, &bytes, end);

    var rebuilt = try db.index.rebuild(testing.allocator, metadata, &.{bytes[0..end]}, 8);
    defer rebuilt.deinit();
    var index: db.index.Index = .{
        .allocator = testing.allocator,
        .region = metadata.region,
        .generation = 1,
        .max_keys = 8,
        .segment_ids = metadata.segments,
    };
    defer index.deinit();
    index.publish(try index.prepareBatches(&.{ .{ .entries = &first }, .{ .entries = &second } }, 48, 0));

    try testing.expectEqual(rebuilt.count(), index.count());
    try testing.expectEqual(@as(u64, 2), index.last_batch_id);
    for (0..3) |x| try testing.expectEqualDeep(try rebuilt.get(item(1, @intCast(x), "").key), try index.get(item(1, @intCast(x), "").key));
    try testing.expectError(error.BatchOrder, index.prepareBatches(&.{.{ .entries = &second }}, end, 0));
}
