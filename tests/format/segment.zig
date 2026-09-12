const std = @import("std");
const segment = @import("zigitedb").segment;
const testing = std.testing;

const header: segment.Header = .{
    .segment_id = 0x0807060504030201,
    .generation = 9,
    .region = .{ .dimension = -1, .x = -2, .z = 3 },
};

fn checksum(bytes: *[segment.encoded_len]u8) void {
    std.mem.writeInt(u32, bytes[44..48], std.hash.crc.Crc32Iscsi.hash(bytes[0..44]), .little);
}

test "segment header bytes" {
    const bytes = try header.encode();
    try testing.expectEqualSlices(u8, &.{
        'Z', 'G', 'S', 'G', 1,   0,   0,   0,
        1,   2,   3,   4,   5,   6,   7,   8,
        9,   0,   0,   0,   0,   0,   0,   0,
        255, 255, 255, 255, 254, 255, 255, 255,
        3,   0,   0,   0,   0,   0,   0,   0,
        0,   0,   0,   0,
    }, bytes[0..44]);
    try testing.expectEqualDeep(header, try segment.Header.decode(&bytes));
}

test "large segment IDs and negative coordinates" {
    const extreme: segment.Header = .{
        .segment_id = std.math.maxInt(u64),
        .generation = std.math.maxInt(u64),
        .region = .{
            .dimension = std.math.minInt(i32),
            .x = @divFloor(std.math.minInt(i32), 32),
            .z = @divFloor(std.math.maxInt(i32), 32),
        },
    };
    try testing.expectEqualDeep(extreme, try segment.Header.decode(&(try extreme.encode())));
}

test "damaged segment header" {
    const bytes = try header.encode();
    for (0..segment.encoded_len) |len| {
        try testing.expectError(error.TruncatedHeader, segment.Header.decode(bytes[0..len]));
    }
    for (0..segment.encoded_len * 8) |bit| {
        var damaged = bytes;
        damaged[bit / 8] ^= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        const expected = if (bit < 32)
            error.InvalidMagic
        else if (bit < 48)
            error.UnsupportedVersion
        else
            error.ChecksumMismatch;
        try testing.expectError(expected, segment.Header.decode(&damaged));
    }
}

test "reserved segment fields" {
    for ([_]usize{ 6, 7, 36, 37, 38, 39, 40, 41, 42, 43 }) |offset| {
        var bytes = try header.encode();
        bytes[offset] = 1;
        checksum(&bytes);
        try testing.expectError(error.InvalidFlags, segment.Header.decode(&bytes));
    }
}

test "zero segment IDs" {
    var invalid = header;
    invalid.segment_id = 0;
    try testing.expectError(error.InvalidSegmentId, invalid.encode());
    invalid = header;
    invalid.generation = 0;
    try testing.expectError(error.InvalidGeneration, invalid.encode());

    for ([_]usize{ 8, 16 }) |offset| {
        var bytes = try header.encode();
        @memset(bytes[offset..][0..8], 0);
        checksum(&bytes);
        const expected = if (offset == 8) error.InvalidSegmentId else error.InvalidGeneration;
        try testing.expectError(expected, segment.Header.decode(&bytes));
    }
}

test "wrong segment identity" {
    const decoded = try segment.Header.decode(&(try header.encode()));
    try decoded.checkIdentity(header);
    inline for (.{ "segment_id", "generation" }) |field| {
        var other = header;
        @field(other, field) += 1;
        try testing.expectError(error.IdentityMismatch, decoded.checkIdentity(other));
    }
    inline for (.{ "dimension", "x", "z" }) |field| {
        var other = header;
        @field(other.region, field) += 1;
        try testing.expectError(error.IdentityMismatch, decoded.checkIdentity(other));
    }
}

test "header followed by records" {
    var bytes: [segment.encoded_len + 16]u8 = undefined;
    @memcpy(bytes[0..segment.encoded_len], &(try header.encode()));
    @memset(bytes[segment.encoded_len..], 255);
    try testing.expectEqualDeep(header, try segment.Header.decode(&bytes));
}
