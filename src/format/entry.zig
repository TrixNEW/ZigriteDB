const std = @import("std");
const Key = @import("key.zig").Key;
const record = @import("record.zig");
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const checksum_len = 4;
pub const overhead = record.encoded_len + Key.encoded_len + checksum_len;
pub const Error = record.Error || Key.DecodeError || error{
    BufferTooSmall,
    TruncatedRecord,
    UnsupportedRecordKind,
};

/// Value bytes borrow the caller's buffer. Only raw puts and deletes are supported.
pub const Entry = struct {
    header: record.Header,
    key: Key,
    value: []const u8,

    pub fn size(self: Entry) Error!usize {
        _ = try self.header.encode();
        _ = try self.key.encode();
        try validateHeader(self.header);
        if (self.value.len != self.header.stored_len) return error.InvalidLength;
        return totalSize(self.header.stored_len);
    }

    /// The destination must not overlap value. Errors leave it unchanged.
    pub fn encode(self: Entry, destination: []u8) Error![]u8 {
        const len = try self.size();
        if (destination.len < len) return error.BufferTooSmall;

        const header_bytes = try self.header.encode();
        const key_bytes = try self.key.encode();
        const key_end = record.encoded_len + Key.encoded_len;
        const checksum_offset = len - checksum_len;
        const bytes = destination[0..len];

        @memcpy(bytes[0..record.encoded_len], &header_bytes);
        @memcpy(bytes[record.encoded_len..key_end], &key_bytes);
        @memcpy(bytes[key_end..checksum_offset], self.value);
        std.mem.writeInt(u32, bytes[checksum_offset..][0..4], Crc32c.hash(bytes[0..checksum_offset]), .little);
        return bytes;
    }
};

pub const Decoded = struct {
    entry: Entry,
    consumed: usize,
};

/// Verifies one record prefix. The returned value borrows bytes.
pub fn decode(bytes: []const u8) Error!Decoded {
    const header = try record.Header.decode(bytes);
    try validateHeader(header);
    const len = try totalSize(header.stored_len);
    if (bytes.len < len) return error.TruncatedRecord;

    const checksum_offset = len - checksum_len;
    const expected = std.mem.readInt(u32, bytes[checksum_offset..][0..4], .little);
    if (expected != Crc32c.hash(bytes[0..checksum_offset])) return error.ChecksumMismatch;

    const key_end = record.encoded_len + Key.encoded_len;
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
    if (header.compression != .none) return error.UnsupportedCompression;
}

fn totalSize(stored_len: u32) Error!usize {
    return std.math.add(usize, overhead, stored_len) catch error.InvalidLength;
}
