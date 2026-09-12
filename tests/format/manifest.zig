const std = @import("std");
const manifest = @import("zigitedb").manifest;
const testing = std.testing;

const example: manifest.Manifest = .{
    .generation = 7,
    .region = .{ .dimension = -1, .x = -2, .z = 3 },
    .segments = &.{ 1, 4, 9 },
};

fn checksums(bytes: []u8) void {
    std.mem.writeInt(u32, bytes[44..48], std.hash.crc.Crc32Iscsi.hash(bytes[0..44]), .little);
    const end = bytes.len - 4;
    std.mem.writeInt(u32, bytes[end..][0..4], std.hash.crc.Crc32Iscsi.hash(bytes[0..end]), .little);
}

test "manifest round trip" {
    var buffer: [128]u8 = undefined;
    var ids: [3]u64 = undefined;
    const bytes = try example.encode(&buffer);
    const decoded = try manifest.decode(bytes, &ids);
    try testing.expectEqualDeep(example, decoded);
    try testing.expectEqual(@intFromPtr(&ids), @intFromPtr(decoded.segments.ptr));
    try testing.expectEqualSlices(u8, "ZGMF", bytes[0..4]);
    try testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 0, 0, 0, 0 }, bytes[8..16]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }, bytes[48..56]);
}

test "damaged manifest leaves output unchanged" {
    var buffer: [128]u8 = undefined;
    var ids = [_]u64{99} ** 3;
    const before = ids;
    const bytes = try example.encode(&buffer);
    for (0..bytes.len) |len| {
        try testing.expectError(error.TruncatedManifest, manifest.decode(bytes[0..len], &ids));
        try testing.expectEqualSlices(u64, &before, &ids);
    }
    for (0..bytes.len * 8) |bit| {
        const mask = @as(u8, 1) << @as(u3, @intCast(bit % 8));
        bytes[bit / 8] ^= mask;
        const expected = if (bit < 32) error.InvalidMagic else if (bit < 48) error.UnsupportedVersion else error.ChecksumMismatch;
        try testing.expectError(expected, manifest.decode(bytes, &ids));
        try testing.expectEqualSlices(u64, &before, &ids);
        bytes[bit / 8] ^= mask;
    }
}

test "invalid manifest fields" {
    var buffer: [128]u8 = undefined;
    var ids = [_]u64{99} ** 3;
    const before = ids;
    const Case = struct { offset: usize, value: u8, expected: manifest.Error };
    const cases = [_]Case{
        .{ .offset = 6, .value = 1, .expected = error.InvalidFlags },
        .{ .offset = 40, .value = 1, .expected = error.InvalidFlags },
        .{ .offset = 8, .value = 0, .expected = error.InvalidGeneration },
        .{ .offset = 28, .value = 0, .expected = error.InvalidSegmentCount },
        .{ .offset = 32, .value = 1, .expected = error.InvalidActiveSegment },
        .{ .offset = 48, .value = 0, .expected = error.InvalidSegmentId },
        .{ .offset = 56, .value = 1, .expected = error.InvalidSegmentOrder },
        .{ .offset = 64, .value = 2, .expected = error.InvalidSegmentOrder },
    };
    for (cases) |case| {
        const bytes = try example.encode(&buffer);
        bytes[case.offset] = case.value;
        checksums(bytes);
        try testing.expectError(case.expected, manifest.decode(bytes, &ids));
        try testing.expectEqualSlices(u64, &before, &ids);
    }
}

test "manifest limits" {
    var buffer: [128]u8 = undefined;
    var ids: [3]u64 = undefined;
    const bytes = try example.encode(&buffer);
    try testing.expectError(error.BufferTooSmall, manifest.decode(bytes, ids[0..2]));
    try testing.expectError(error.InvalidLength, manifest.decode(buffer[0 .. bytes.len + 1], &ids));
    std.mem.writeInt(u32, bytes[28..32], std.math.maxInt(u32), .little);
    checksums(bytes);
    try testing.expectError(error.InvalidSegmentCount, manifest.decode(bytes, &ids));

    var invalid = example;
    invalid.segments = &.{};
    try testing.expectError(error.InvalidSegmentCount, invalid.encode(&buffer));
    invalid = example;
    invalid.segments = &.{ 1, 1 };
    try testing.expectError(error.InvalidSegmentOrder, invalid.encode(&buffer));
    invalid.segments = &.{0};
    try testing.expectError(error.InvalidSegmentId, invalid.encode(&buffer));
    invalid = example;
    invalid.generation = 0;
    try testing.expectError(error.InvalidGeneration, invalid.encode(&buffer));
}

test "short output buffer" {
    var buffer = [_]u8{0xaa} ** 16;
    const before = buffer;
    try testing.expectError(error.BufferTooSmall, example.encode(&buffer));
    try testing.expectEqualSlices(u8, &before, &buffer);
}

test "largest allowed manifest" {
    var ids: [manifest.max_segments]u64 = undefined;
    var decoded_ids: [manifest.max_segments]u64 = undefined;
    var buffer: [manifest.max_encoded_len]u8 = undefined;
    for (&ids, 0..) |*id, index| id.* = index + 1;
    var large = example;
    large.segments = &ids;
    const bytes = try large.encode(&buffer);
    try testing.expectEqual(manifest.max_encoded_len, bytes.len);
    try testing.expectEqualDeep(large, try manifest.decode(bytes, &decoded_ids));
}
