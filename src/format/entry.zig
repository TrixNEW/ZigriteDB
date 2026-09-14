const std = @import("std");
const Crc32c = std.hash.crc.Crc32Iscsi;

const key_format = @import("key.zig");
const Key = key_format.Key;
const lz4 = @import("../compression/lz4.zig");
const record = @import("record.zig");

pub const checksum_len = 4;
pub const overhead = record.encoded_len + Key.encoded_len + checksum_len;

pub const Error = lz4.Error || record.Error || Key.DecodeError || error{
    BufferTooSmall,
    TruncatedRecord,
    UnsupportedRecordKind,
};

pub const Entry = struct {
    header: record.Header,
    key: Key,
    value: []const u8,

    /// Scratch must not overlap value; compressed results borrow it.
    pub fn compress(self: Entry, encoder: *lz4.Encoder, scratch: []u8) Error!Entry {
        _ = try self.size();
        if (self.header.kind != .put or self.header.compression != .none) return self;
        const compressed = try encoder.compress(self.value, scratch);
        if (compressed.len >= self.value.len) return self;
        var result = self;
        result.header.compression = .lz4;
        result.header.stored_len = @intCast(compressed.len);
        result.value = compressed;
        return result;
    }

    pub fn size(self: Entry) Error!usize {
        _ = try self.header.encode();
        _ = try self.key.encode();

        try validateHeader(self.header);
        if (self.value.len != self.header.stored_len) return error.InvalidLength;

        if (self.header.compression == .lz4) try lz4.validate(self.value, self.header.raw_len);
        return totalSize(self.header.stored_len);
    }

    /// `destination` must not overlap `value`
    /// Errors leave it unchanged
    pub fn encode(self: Entry, destination: []u8) Error![]u8 {
        _ = try self.size();
        const header_bytes = try self.header.encode();
        const key_bytes = try self.key.encode();

        try validateHeader(self.header);
        if (self.value.len != self.header.stored_len) return error.InvalidLength;

        const len = try totalSize(self.header.stored_len);
        if (destination.len < len) return error.BufferTooSmall;

        const key_end = record.encoded_len + Key.encoded_len;
        const checksum_offset = len - checksum_len;
        const bytes = destination[0..len];

        @memcpy(bytes[0..record.encoded_len], &header_bytes);
        @memcpy(bytes[record.encoded_len..key_end], &key_bytes);
        @memcpy(bytes[key_end..checksum_offset], self.value);

        const checksum = Crc32c.hash(bytes[0..checksum_offset]);
        std.mem.writeInt(u32, bytes[checksum_offset..][0..checksum_len], checksum, .little);

        return bytes;
    }
};

pub const Decoded = struct {
    entry: Entry,
    consumed: usize,
};

/// The decoded value borrows from `bytes`
pub fn decode(bytes: []const u8) Error!Decoded {
    const header = try record.Header.decode(bytes);
    try validateHeader(header);

    const len = try totalSize(header.stored_len);
    if (bytes.len < len) return error.TruncatedRecord;

    const checksum_offset = len - checksum_len;
    const expected_checksum = std.mem.readInt(u32, bytes[checksum_offset..][0..checksum_len], .little);
    const actual_checksum = Crc32c.hash(bytes[0..checksum_offset]);

    if (expected_checksum != actual_checksum) return error.ChecksumMismatch;

    const key_end = record.encoded_len + Key.encoded_len;

    if (header.compression == .lz4) try lz4.validate(bytes[key_end..checksum_offset], header.raw_len);

    return .{
        .entry = .{
            .header = header,
            .key = try Key.decode(bytes[record.encoded_len..key_end]),
            .value = bytes[key_end..checksum_offset],
        },
        .consumed = len,
    };
}

fn validateHeader(header: record.Header) Error!void {
    if (header.kind == .commit) return error.UnsupportedRecordKind;
}

fn totalSize(stored_len: u32) Error!usize {
    return std.math.add(usize, overhead, stored_len) catch error.InvalidLength;
}
