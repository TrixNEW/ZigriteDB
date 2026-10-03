const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const record = db.record;
const frame = db.frame;
const segment = db.segment;
const manifest = db.manifest;

test "keys validate subchunk Y and reject it elsewhere" {
    const ok: db.Key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .subchunk, .subchunk_y = -128 };
    try ok.validate();
    var bad = ok;
    bad.subchunk_y = 128;
    try testing.expectError(error.InvalidSubchunkY, bad.validate());
    bad = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .version, .subchunk_y = 1 };
    try testing.expectError(error.InvalidSubchunkY, bad.validate());
    const unknown: db.Key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = @enumFromInt(0x99) };
    try unknown.validate();
}

test "regions use floor division at the extremes" {
    const cases = [_]struct { x: i32, region: i32, slot: u10 }{
        .{ .x = 0, .region = 0, .slot = 0 },
        .{ .x = 31, .region = 0, .slot = 31 },
        .{ .x = 32, .region = 1, .slot = 0 },
        .{ .x = -1, .region = -1, .slot = 31 },
        .{ .x = -32, .region = -1, .slot = 0 },
        .{ .x = -33, .region = -2, .slot = 31 },
        .{ .x = std.math.minInt(i32), .region = std.math.minInt(i32) / 32, .slot = 0 },
        .{ .x = std.math.maxInt(i32), .region = std.math.maxInt(i32) >> 5, .slot = 31 },
    };
    for (cases) |case| {
        const key: db.Key = .{ .dimension = 0, .chunk_x = case.x, .chunk_z = 0, .component = .version };
        try testing.expectEqual(case.region, key.region().x);
        try testing.expectEqual(case.slot, key.slot());
        try testing.expectEqual(key, db.Key.fromLocal(key.region(), key.slot(), key.local()));
    }
}

test "record header bytes" {
    var bytes: [record.header_len]u8 = undefined;
    const header: record.Header = .{ .slot = 0x3ff, .local = db.Key.local(.{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .subchunk, .subchunk_y = -4 }), .compression = .lz4, .stored_len = 5, .raw_len = 0x00020304 };
    header.write(&bytes);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x0b, 0x2f, 0xfc, 5, 0, 0, 0, 4, 3, 2, 0 }, &bytes);
    try testing.expectEqual(header, try record.Header.read(&bytes));
}

test "record headers reject bad flags, lengths and stray Y bytes" {
    var bytes: [record.header_len]u8 = undefined;
    (record.Header{ .slot = 1, .local = 0x2c80, .stored_len = 3, .raw_len = 3 }).write(&bytes);
    _ = try record.Header.read(&bytes);

    var damaged = bytes;
    damaged[1] |= 0x20;
    try testing.expectError(error.InvalidFlags, record.Header.read(&damaged));
    damaged = bytes;
    damaged[1] |= 0x10;
    try testing.expectError(error.UnsupportedCompression, record.Header.read(&damaged));
    damaged = bytes;
    damaged[3] = 1;
    try testing.expectError(error.InvalidFlags, record.Header.read(&damaged));
    damaged = bytes;
    damaged[8] = 9;
    try testing.expectError(error.InvalidLength, record.Header.read(&damaged));
    (record.Header{ .slot = 1, .local = 0x2c80, .delete = true }).write(&damaged);
    damaged[4] = 1;
    try testing.expectError(error.InvalidLength, record.Header.read(&damaged));
}

test "records detect any damaged bit and any truncation" {
    var buffer: [64]u8 = undefined;
    (record.Header{ .slot = 7, .local = 0x2c80, .stored_len = 5, .raw_len = 5 }).write(buffer[0..record.header_len]);
    @memcpy(buffer[record.header_len..][0..5], "value");
    const len = record.overhead + 5;
    _ = record.seal(buffer[0..len]);
    const decoded = try record.decode(buffer[0..len]);
    try testing.expectEqualStrings("value", decoded.value);
    try testing.expectEqual(len, decoded.len);
    for (0..len) |cut| try testing.expectError(error.TruncatedRecord, record.decode(buffer[0..cut]));
    for (0..len * 8) |bit| {
        var damaged = buffer;
        damaged[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try testing.expect(std.meta.isError(record.decode(damaged[0..len])));
    }
}

fn buildFrame(buffer: []u8, salt: u64, id: u64) ![]u8 {
    var builder: frame.Builder = .init(buffer);
    try builder.add(1, 0x2c80, "first", null, 0);
    try builder.add(2, 0x2c80, null, null, 0);
    return builder.finish(.batch, id, salt);
}

fn ignore(_: void, _: usize, _: record.Header, _: []const u8) void {}

test "frame header bytes and verification" {
    var buffer: [256]u8 = undefined;
    const bytes = try buildFrame(&buffer, 5, 0x0102030405060708);
    try testing.expectEqual(@as(usize, frame.header_len + 2 * record.overhead + 5), bytes.len);
    try testing.expectEqual(@as(u32, @intCast(bytes.len - frame.header_len)), std.mem.readInt(u32, bytes[0..4], .little));
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[4..6], .little));
    try testing.expectEqual(@as(u8, 1), bytes[6]);
    try testing.expectEqual(@as(u64, 0x0102030405060708), std.mem.readInt(u64, bytes[8..16], .little));
    const header = try frame.verify(bytes, 5, {}, ignore);
    try testing.expectEqual(@as(u16, 2), header.count);
}

test "frames reject reordered records, other salts and bad IDs" {
    var buffer: [256]u8 = undefined;
    const bytes = try buildFrame(&buffer, 5, 1);
    try testing.expectError(error.ChecksumMismatch, frame.verify(bytes, 6, {}, ignore));

    // Each record still checks out alone.
    const first_len = record.overhead + 5;
    var swapped: [256]u8 = undefined;
    @memcpy(swapped[0..frame.header_len], bytes[0..frame.header_len]);
    @memcpy(swapped[frame.header_len..][0 .. bytes.len - frame.header_len - first_len], bytes[frame.header_len + first_len ..]);
    @memcpy(swapped[bytes.len - first_len .. bytes.len], bytes[frame.header_len..][0..first_len]);
    try testing.expectError(error.BatchMismatch, frame.verify(swapped[0..bytes.len], 5, {}, ignore));

    var zero_id: [256]u8 = undefined;
    var builder: frame.Builder = .init(&zero_id);
    try builder.add(1, 0x2c80, "x", null, 0);
    const invalid = builder.finish(.batch, 0, 5);
    try testing.expectError(error.InvalidFrame, frame.verify(invalid, 5, {}, ignore));
}

test "builders compress only when it helps and respect the threshold" {
    var buffer: [8192]u8 = undefined;
    var encoder: db.lz4.Encoder = .{};
    var repetitive: [2048]u8 = undefined;
    for (&repetitive, 0..) |*b, i| b.* = @truncate(i / 128);
    var builder: frame.Builder = .init(&buffer);
    try builder.add(0, 0x2b80, &repetitive, &encoder, 4096);
    try builder.add(0, 0x2c80, &repetitive, &encoder, 256);
    try builder.add(0, 0x2d80, "tiny value", &encoder, 4);
    const bytes = builder.finish(.batch, 1, 1);
    const Expect = struct {
        index: usize = 0,
        fn visit(self: *@This(), _: usize, header: record.Header, _: []const u8) !void {
            const expected: record.Compression = if (self.index == 1) .lz4 else .none;
            try testing.expectEqual(expected, header.compression);
            self.index += 1;
        }
    };
    var expect: Expect = .{};
    _ = try frame.verify(bytes, 1, &expect, Expect.visit);
    try testing.expectEqual(@as(usize, 3), expect.index);
    var small: [frame.header_len + record.overhead]u8 = undefined;
    var full: frame.Builder = .init(&small);
    try testing.expectError(error.BufferTooSmall, full.add(0, 0x2c80, "x", null, 0));
}

const segment_header: segment.Header = .{
    .segment_id = 0x0807060504030201,
    .generation = 9,
    .region = .{ .dimension = -1, .x = -2, .z = 3 },
    .salt = 0x1112131415161718,
};

test "segment header bytes" {
    const bytes = try segment_header.encode();
    try testing.expectEqualSlices(u8, &.{
        'Z',  'G',  'S',  'G',  2,    0,    0,    0,
        1,    2,    3,    4,    5,    6,    7,    8,
        9,    0,    0,    0,    0,    0,    0,    0,
        255,  255,  255,  255,  254,  255,  255,  255,
        3,    0,    0,    0,    0x18, 0x17, 0x16, 0x15,
        0x14, 0x13, 0x12, 0x11,
    }, bytes[0..44]);
    try testing.expectEqualDeep(segment_header, try segment.Header.decode(&bytes));
}

test "damaged segment headers and identity" {
    const bytes = try segment_header.encode();
    for (0..segment.encoded_len) |len| try testing.expectError(error.TruncatedHeader, segment.Header.decode(bytes[0..len]));
    for (0..segment.encoded_len * 8) |bit| {
        var damaged = bytes;
        damaged[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        const expected = if (bit < 32) error.InvalidMagic else if (bit < 48) error.UnsupportedVersion else error.ChecksumMismatch;
        try testing.expectError(expected, segment.Header.decode(&damaged));
    }
    var v1 = bytes;
    v1[4] = 1;
    try testing.expectError(error.UnsupportedVersion, segment.Header.decode(&v1));

    var other = segment_header;
    try segment_header.checkIdentity(other);
    other.salt = 0;
    try segment_header.checkIdentity(other);
    other.salt = 1;
    try testing.expectError(error.IdentityMismatch, segment_header.checkIdentity(other));
    try testing.expectError(error.InvalidSegmentId, (segment.Header{ .segment_id = 0, .generation = 1, .region = segment_header.region, .salt = 1 }).encode());
}

test "manifests round trip and reject damage" {
    var buffer: [manifest.max_encoded_len]u8 = undefined;
    const original: manifest.Manifest = .{ .generation = 3, .region = .{ .dimension = 1, .x = -5, .z = 6 }, .segments = &.{ 1, 4, 9 }, .base_batch_id = 77, .salt = 99 };
    const bytes = try original.encode(&buffer);
    var ids: [manifest.max_segments]u64 = undefined;
    const decoded = try manifest.decode(bytes, &ids);
    try testing.expectEqualDeep(original.segments, decoded.segments);
    try testing.expectEqual(@as(u64, 77), decoded.base_batch_id);
    try testing.expectEqual(@as(u64, 99), decoded.salt);
    try testing.expectEqual(@as(?u16, 2), manifest.peekVersion(bytes));

    for (0..bytes.len * 8) |bit| {
        var damaged: [manifest.max_encoded_len]u8 = undefined;
        @memcpy(damaged[0..bytes.len], bytes);
        damaged[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try testing.expect(std.meta.isError(manifest.decode(damaged[0..bytes.len], &ids)));
    }
    try testing.expectError(error.InvalidSegmentOrder, (manifest.Manifest{ .generation = 1, .region = original.region, .segments = &.{ 2, 2 }, .salt = 1 }).encode(&buffer));
    try testing.expectError(error.InvalidSegmentCount, (manifest.Manifest{ .generation = 1, .region = original.region, .segments = &.{}, .salt = 1 }).encode(&buffer));
    try testing.expectError(error.InvalidLength, manifest.decode(buffer[0 .. bytes.len + 1], &ids));
    try testing.expectError(error.BufferTooSmall, manifest.decode(bytes, ids[0..2]));
}
