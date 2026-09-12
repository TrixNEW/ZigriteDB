const std = @import("std");
const record = @import("zigitedb").record;
const Header = record.Header;
const Error = record.Error;
const encoded_len = record.encoded_len;
const max_value_len = record.max_value_len;

test "CRC32C standard check vector" {
    try std.testing.expectEqual(@as(u32, 0xe3069283), std.hash.crc.Crc32Iscsi.hash("123456789"));
}

test "header round trips every record kind and codec" {
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
        try std.testing.expectEqualDeep(header, try Header.decode(&bytes));
        try std.testing.expectEqualSlices(u8, "ZGRC", bytes[0..4]);
        try std.testing.expectEqual(@as(u8, 1), bytes[4]);
    }
}

test "every truncated header and single bit corruption is rejected" {
    const bytes = try (Header{ .kind = .put, .batch_id = 1, .stored_len = 256, .raw_len = 256 }).encode();
    for (0..encoded_len) |len| {
        try std.testing.expectError(error.TruncatedHeader, Header.decode(bytes[0..len]));
    }
    for (0..encoded_len * 8) |bit| {
        var damaged = bytes;
        damaged[bit / 8] ^= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        if (Header.decode(&damaged)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "invalid lengths and batch identifiers fail before encoding" {
    const cases = [_]Header{
        .{ .kind = .put, .batch_id = 0 },
        .{ .kind = .put, .batch_id = 1, .stored_len = max_value_len + 1, .raw_len = max_value_len + 1 },
        .{ .kind = .put, .batch_id = 1, .stored_len = 1, .raw_len = 2 },
        .{ .kind = .put, .batch_id = 1, .compression = .lz4, .raw_len = 2 },
        .{ .kind = .put, .batch_id = 1, .compression = .lz4, .stored_len = 2, .raw_len = 2 },
        .{ .kind = .delete, .batch_id = 1, .stored_len = 1 },
        .{ .kind = .commit, .batch_id = 1, .compression = .lz4 },
    };
    for (cases) |header| {
        if (header.encode()) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "checksummed invalid metadata is rejected" {
    const bytes = try (Header{ .kind = .put, .batch_id = 1 }).encode();
    const offsets = [_]usize{ 5, 6, 7, 24, 11, 15, 16 };
    const errors = [_]Error{ error.UnknownKind, error.UnsupportedCompression, error.InvalidFlags, error.InvalidFlags, error.InvalidLength, error.InvalidLength, error.InvalidBatchId };
    for (offsets, errors) |offset, expected| {
        var damaged = bytes;
        damaged[offset] = if (offset == 16) 0 else 255;
        std.mem.writeInt(u32, damaged[28..32], std.hash.crc.Crc32Iscsi.hash(damaged[0..28]), .little);
        try std.testing.expectError(expected, Header.decode(&damaged));
    }
}
