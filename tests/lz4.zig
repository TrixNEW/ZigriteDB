const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const item = @import("support/shard.zig").item;

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

test "compressed entries fall back to raw and validate their payload" {
    var encoder: db.lz4.Encoder = .{};
    var scratch: [2048]u8 = undefined;
    const raw = [_]u8{'a'} ** 1024;
    const compressed = try item(1, 0, &raw).compress(&encoder, &scratch);
    try testing.expectEqual(db.record.Compression.lz4, compressed.header.compression);
    var encoded: [2048]u8 = undefined;
    const bytes = try compressed.encode(&encoded);
    _ = try db.entry.decode(bytes);
    const payload = db.record.encoded_len + db.Key.encoded_len;
    bytes[payload + 2] = 0;
    bytes[payload + 3] = 0;
    const checksum = bytes.len - 4;
    std.mem.writeInt(u32, bytes[checksum..][0..4], std.hash.crc.Crc32Iscsi.hash(bytes[0..checksum]), .little);
    try testing.expectError(error.InvalidCompressedData, db.entry.decode(bytes));
    const small = try item(2, 1, "hello").compress(&encoder, &scratch);
    try testing.expectEqual(db.record.Compression.none, small.header.compression);
    try testing.expectEqualStrings("hello", small.value);
}

test "compressed values survive reopen and compaction" {
    if (!db.directory.supported) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var encoder: db.lz4.Encoder = .{};
    var scratch: [2048]u8 = undefined;
    const raw = [_]u8{'x'} ** 1024;
    const compressed = try item(1, 0, &raw).compress(&encoder, &scratch);
    var store = try db.Store.create(testing.allocator, io, tmp.dir, @import("support/shard.zig").header.region, .{ .batch_buffer_size = 256 });
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{compressed} });
    try store.close();
    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, .{ .batch_buffer_size = 256 });
    defer reopened.deinit();
    var output: [1024]u8 = undefined;
    try testing.expectEqualSlices(u8, &raw, (try reopened.get(compressed.key, &output)).?);
    try testing.expectError(error.BufferTooSmall, reopened.get(compressed.key, output[0..10]));
    _ = try reopened.compact();
    try testing.expectEqualSlices(u8, &raw, (try reopened.get(compressed.key, &output)).?);
    try reopened.close();
}
