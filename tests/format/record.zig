const std = @import("std");
const record = @import("zigitedb").record;
const Header = record.Header;
const Error = record.Error;
const encoded_len = record.encoded_len;
const max_value_len = record.max_value_len;
const testing = std.testing;

test "record header round trip" {
    const headers = [_]Header{
        .{ .kind = .put, .batch_id = 1 },
        .{
            .kind = .put,
            .stored_len = max_value_len,
            .raw_len = max_value_len,
            .batch_id = std.math.maxInt(u64),
        },
        .{ .kind = .put, .compression = .lz4, .stored_len = 128, .raw_len = 512, .batch_id = 2 },
        .{ .kind = .delete, .batch_id = 3 },
        .{ .kind = .commit, .batch_id = 4 },
    };
    for (headers) |header| {
        const bytes = try header.encode();
        try testing.expectEqualDeep(header, try Header.decode(&bytes));
    }
}

test "damaged record header" {
    const bytes = try (Header{ .kind = .put, .batch_id = 1, .stored_len = 256, .raw_len = 256 }).encode();
    for (0..encoded_len) |len| {
        try testing.expectError(error.TruncatedHeader, Header.decode(bytes[0..len]));
    }
    for (0..encoded_len * 8) |bit| {
        var damaged = bytes;
        damaged[bit / 8] ^= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        const expected = if (bit < 32)
            error.InvalidMagic
        else if (bit < 40)
            error.UnsupportedVersion
        else
            error.ChecksumMismatch;
        try testing.expectError(expected, Header.decode(&damaged));
    }
}

test "invalid record fields" {
    try testing.expectError(error.InvalidBatchId, (Header{ .kind = .put, .batch_id = 0 }).encode());
    const cases = [_]Header{
        .{ .kind = .put, .batch_id = 1, .stored_len = max_value_len + 1, .raw_len = max_value_len + 1 },
        .{ .kind = .put, .batch_id = 1, .stored_len = 1, .raw_len = 2 },
        .{ .kind = .put, .batch_id = 1, .compression = .lz4, .raw_len = 2 },
        .{ .kind = .put, .batch_id = 1, .compression = .lz4, .stored_len = 2, .raw_len = 2 },
        .{ .kind = .delete, .batch_id = 1, .stored_len = 1 },
        .{ .kind = .commit, .batch_id = 1, .compression = .lz4 },
    };
    for (cases) |header| {
        try testing.expectError(error.InvalidLength, header.encode());
    }
}

test "invalid header with a valid checksum" {
    const bytes = try (Header{ .kind = .put, .batch_id = 1 }).encode();
    const Case = struct { offset: usize, value: u8 = 255, expected: Error };
    const cases = [_]Case{
        .{ .offset = 5, .expected = error.UnknownKind },
        .{ .offset = 6, .expected = error.UnsupportedCompression },
        .{ .offset = 7, .expected = error.InvalidFlags },
        .{ .offset = 24, .expected = error.InvalidFlags },
        .{ .offset = 11, .expected = error.InvalidLength },
        .{ .offset = 15, .expected = error.InvalidLength },
        .{ .offset = 16, .value = 0, .expected = error.InvalidBatchId },
    };
    for (cases) |case| {
        var damaged = bytes;
        damaged[case.offset] = case.value;
        std.mem.writeInt(u32, damaged[28..32], std.hash.crc.Crc32Iscsi.hash(damaged[0..28]), .little);
        try testing.expectError(case.expected, Header.decode(&damaged));
    }
}
