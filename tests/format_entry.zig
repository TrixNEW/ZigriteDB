const std = @import("std");
const db = @import("zigritedb");
const entry = db.entry;
const testing = std.testing;

const key: db.Key = .{
    .dimension = -1,
    .chunk_x = -32,
    .chunk_z = 128,
    .component = .subchunk,
    .subchunk_y = -4,
};

fn put(value: []const u8) entry.Entry {
    return .{
        .header = .{
            .kind = .put,
            .batch_id = 42,
            .stored_len = @intCast(value.len),
            .raw_len = @intCast(value.len),
        },
        .key = key,
        .value = value,
    };
}

test "puts and deletes round trip" {
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{ "", "chunk data", &.{ 0, 255, 0, 128 } }) |value| {
        const original = put(value);
        const bytes = try original.encode(&buffer);
        const decoded = try entry.decode(bytes);
        try testing.expectEqualDeep(original, decoded.entry);
        try testing.expectEqual(bytes.len, decoded.consumed);
        const value_start = db.record.encoded_len + db.Key.encoded_len;
        try testing.expect(bytes[value_start..].ptr == decoded.entry.value.ptr);
    }

    const tombstone: entry.Entry = .{
        .header = .{ .kind = .delete, .batch_id = 43 },
        .key = key,
        .value = "",
    };
    const decoded = try entry.decode(try tombstone.encode(&buffer));
    try testing.expectEqualDeep(tombstone, decoded.entry);
}

test "read one record at a time" {
    var buffer: [256]u8 = undefined;
    const first = try put("first").encode(&buffer);
    const first_len = first.len;
    const second = try put("second").encode(buffer[first_len..]);
    const decoded = try entry.decode(buffer[0 .. first_len + second.len]);
    try testing.expectEqual(first_len, decoded.consumed);
    try testing.expectEqualStrings("first", decoded.entry.value);
    const next = try entry.decode(buffer[decoded.consumed .. first_len + second.len]);
    try testing.expectEqualStrings("second", next.entry.value);
}

test "incomplete record" {
    var buffer: [256]u8 = undefined;
    const bytes = try put("value").encode(&buffer);
    for (0..bytes.len) |len| {
        const expected = if (len < db.record.encoded_len) error.TruncatedHeader else error.TruncatedRecord;
        try testing.expectError(expected, entry.decode(bytes[0..len]));
    }
}

test "damaged record" {
    var buffer: [256]u8 = undefined;
    const bytes = try put("value").encode(&buffer);
    for (db.record.encoded_len * 8..bytes.len * 8) |bit| {
        const mask = @as(u8, 1) << @as(u3, @intCast(bit % 8));
        bytes[bit / 8] ^= mask;
        try testing.expectError(error.ChecksumMismatch, entry.decode(bytes));
        bytes[bit / 8] ^= mask;
    }
}

test "failed encode leaves output unchanged" {
    var buffer = [_]u8{0xaa} ** 128;
    const before = buffer;
    try testing.expectError(error.BufferTooSmall, put("value").encode(buffer[0..entry.overhead]));
    try testing.expectEqualSlices(u8, &before, &buffer);

    var invalid = put("value");
    invalid.header.stored_len += 1;
    try testing.expectError(error.InvalidLength, invalid.encode(&buffer));
    try testing.expectEqualSlices(u8, &before, &buffer);

    invalid = put("value");
    invalid.key.component = .metadata;
    try testing.expectError(error.InvalidSubchunkY, invalid.encode(&buffer));
    try testing.expectEqualSlices(u8, &before, &buffer);
}

test "invalid record kinds and compressed payloads" {
    var buffer: [128]u8 = undefined;
    var invalid = put("");
    invalid.header.kind = .commit;
    try testing.expectError(error.UnsupportedRecordKind, invalid.encode(&buffer));
    const commit = try invalid.header.encode();
    try testing.expectError(error.UnsupportedRecordKind, entry.decode(&commit));

    invalid = put("lz4");
    invalid.header.compression = .lz4;
    invalid.header.raw_len = 100;
    try testing.expectError(error.InvalidCompressedData, invalid.encode(&buffer));
    const compressed = try invalid.header.encode();
    try testing.expectError(error.TruncatedRecord, entry.decode(&compressed));
}

test "invalid key with a valid checksum" {
    var buffer: [128]u8 = undefined;
    const bytes = try put("").encode(&buffer);
    bytes[db.record.encoded_len + 12] = @intFromEnum(db.Component.metadata);
    const checksum_offset = bytes.len - entry.checksum_len;
    std.mem.writeInt(u32, bytes[checksum_offset..][0..4], std.hash.crc.Crc32Iscsi.hash(bytes[0..checksum_offset]), .little);
    try testing.expectError(error.InvalidSubchunkY, entry.decode(bytes));
}

test "oversized record" {
    var bytes = try put("").header.encode();
    std.mem.writeInt(u32, bytes[8..12], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, bytes[12..16], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, bytes[28..32], std.hash.crc.Crc32Iscsi.hash(bytes[0..28]), .little);
    try testing.expectError(error.InvalidLength, entry.decode(&bytes));
}
