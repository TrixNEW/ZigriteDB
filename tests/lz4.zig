const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

test "lz4 handles literals, long matches and window boundaries" {
    var encoder: db.lz4.Encoder = .{};
    var raw: [70000]u8 = undefined;
    var compressed: [70300]u8 = undefined;
    var output: [70000]u8 = undefined;
    var random = std.Random.DefaultPrng.init(42);
    for (0..3) |pattern| {
        random.random().bytes(&raw);
        if (pattern == 1) @memset(&raw, 'a');
        if (pattern == 2) for (&raw, 0..) |*byte, i| {
            byte.* = @intCast(i % 251);
        };
        for ([_]usize{ 0, 1, 5, 12, 13, 15, 255, 4096, 65535, 70000 }) |len| {
            const bytes = try encoder.compress(raw[0..len], &compressed);
            try db.lz4.validate(bytes, len);
            try testing.expectEqualSlices(u8, raw[0..len], try db.lz4.decompress(bytes, &output, len));
        }
    }
}

test "lz4 rejects bad offsets, lengths and truncated blocks" {
    var output: [128]u8 = undefined;
    for ([_][]const u8{ "", &.{0xf0}, &.{ 0x10, 'a', 0, 0 }, &.{ 0x10, 'a', 2, 0 }, &.{ 0x1f, 'a', 1, 0, 255 } }) |bad| {
        try testing.expectError(error.InvalidCompressedData, db.lz4.decompress(bad, &output, 20));
    }
    try testing.expectError(error.InvalidCompressedData, db.lz4.decompress(&.{ 0x10, 'a' }, &output, 2));
    try testing.expectError(error.BufferTooSmall, db.lz4.decompress(&.{ 0x10, 'a' }, &.{}, 1));
    var encoder: db.lz4.Encoder = .{};
    try testing.expectError(error.BufferTooSmall, encoder.compress("hello", output[0..2]));
}

test "compressed records survive reopen and compaction, and damaged streams fail on read" {
    const io = testing.io;
    const support = @import("support/region.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = [_]u8{'x'} ** 1024;
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, support.region, .{ .batch_buffer_size = 2048 });
        defer store.deinit();
        _ = try store.write(support.batch(1, &.{support.put(0, &raw)}));
        try store.close();
    }
    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{ .batch_buffer_size = 2048 });
    defer reopened.deinit();
    var output: [1024]u8 = undefined;
    try testing.expectEqualSlices(u8, &raw, (try reopened.get(support.key(0), &output)).?);
    try testing.expectError(error.BufferTooSmall, reopened.get(support.key(0), output[0..10]));
    _ = try reopened.compact();
    try testing.expectEqualSlices(u8, &raw, (try reopened.get(support.key(0), &output)).?);

    // Break the LZ4 stream but keep the record checksum valid.
    const file = try support.openFile(tmp.dir, "0000000000000002-0000000000000001.segment");
    defer file.handle.close(io);
    const start = db.segment.encoded_len + db.frame.header_len;
    var header: [db.record.header_len]u8 = undefined;
    try file.readExact(&header, start);
    const stored = std.mem.readInt(u32, header[4..8], .little);
    try testing.expect(stored < raw.len);
    var record: [64]u8 = undefined;
    const len = db.record.overhead + stored;
    try file.readExact(record[0..len], start);
    record[db.record.header_len + 2] = 0;
    record[db.record.header_len + 3] = 0;
    _ = db.record.seal(record[0..len]);
    try file.writeAll(record[0..len], start);
    try testing.expectError(error.InvalidCompressedData, reopened.get(support.key(0), &output));
    try reopened.close();
}

test "decompression round-trips every match shape and stays inside the value" {
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    var encoder: db.lz4.Encoder = .{};
    var input: [4096]u8 = undefined;
    var compressed: [4200]u8 = undefined;
    var output: [4096 + 64]u8 = undefined;
    for (0..400) |round| {
        const len = random.uintAtMost(usize, input.len);
        const period = random.intRangeAtMost(usize, 1, 40);
        for (input[0..len], 0..) |*b, i| b.* = if (random.uintLessThan(u8, 8) == 0) random.int(u8) else @truncate(i % period + round);
        const packed_bytes = try encoder.compress(input[0..len], &compressed);
        @memset(&output, 0xee);
        const value = try db.lz4.decompress(packed_bytes, &output, len);
        try std.testing.expectEqualSlices(u8, input[0..len], value);
        for (output[len..]) |b| try std.testing.expectEqual(@as(u8, 0xee), b);
    }
}
