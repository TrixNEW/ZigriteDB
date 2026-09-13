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

    try testing.expectEqual(@as(u64, 2), (try index.get(item(1, 0, "").key)).?.segment_id);
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
