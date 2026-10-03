const std = @import("std");
const crc = @import("crc.zig");

/// One chunk record: a 12-byte header, the stored value, then CRC-32C of both.
///
///   0  u16  bits 0-9 chunk slot, bit 10 delete, bits 11-12 compression
///   2  u8   component tag
///   3  i8   subchunk Y
///   4  u32  stored length
///   8  u32  raw length
pub const header_len = 12;
pub const overhead = header_len + 4;
pub const max_value_len = 16 * 1024 * 1024;

pub const Compression = enum(u2) {
    none = 0,
    lz4 = 1,
};

pub const Error = error{
    TruncatedRecord,
    ChecksumMismatch,
    InvalidFlags,
    UnsupportedCompression,
    InvalidLength,
};

pub const Header = struct {
    slot: u10,
    local: u16,
    delete: bool = false,
    compression: Compression = .none,
    stored_len: u32 = 0,
    raw_len: u32 = 0,

    pub fn validate(self: Header) Error!void {
        if (self.stored_len > max_value_len or self.raw_len > max_value_len) return error.InvalidLength;
        if (self.delete) {
            if (self.stored_len != 0 or self.raw_len != 0 or self.compression != .none) return error.InvalidLength;
            return;
        }
        switch (self.compression) {
            .none => if (self.stored_len != self.raw_len) return error.InvalidLength,
            .lz4 => if (self.stored_len == 0 or self.stored_len >= self.raw_len) return error.InvalidLength,
        }
    }

    pub fn write(self: Header, bytes: *[header_len]u8) void {
        const flags: u16 = @as(u16, self.slot) | @as(u16, @intFromBool(self.delete)) << 10 | @as(u16, @intFromEnum(self.compression)) << 11;
        std.mem.writeInt(u16, bytes[0..2], flags, .little);
        bytes[2] = @truncate(self.local >> 8);
        bytes[3] = @as(u8, @truncate(self.local)) ^ 0x80;
        std.mem.writeInt(u32, bytes[4..8], self.stored_len, .little);
        std.mem.writeInt(u32, bytes[8..12], self.raw_len, .little);
    }

    pub fn read(bytes: *const [header_len]u8) Error!Header {
        const flags = std.mem.readInt(u16, bytes[0..2], .little);
        if (flags >> 13 != 0) return error.InvalidFlags;
        const header: Header = .{
            .slot = @truncate(flags),
            .delete = flags & (1 << 10) != 0,
            .compression = switch (@as(u2, @truncate(flags >> 11))) {
                0 => .none,
                1 => .lz4,
                else => return error.UnsupportedCompression,
            },
            .local = @as(u16, bytes[2]) << 8 | (bytes[3] ^ 0x80),
            .stored_len = std.mem.readInt(u32, bytes[4..8], .little),
            .raw_len = std.mem.readInt(u32, bytes[8..12], .little),
        };
        // Only subchunks carry a Y.
        if (bytes[2] != subchunk_tag and bytes[3] != 0) return error.InvalidFlags;
        try header.validate();
        return header;
    }
};

const subchunk_tag = 0x2f;

pub const Decoded = struct {
    header: Header,
    value: []const u8,
    checksum: u32,
    len: usize,
};

/// Checks one record at the start of `bytes`; the value borrows from it.
pub fn decode(bytes: []const u8) Error!Decoded {
    if (bytes.len < overhead) return error.TruncatedRecord;
    const header = try Header.read(bytes[0..header_len]);
    if (bytes.len - overhead < header.stored_len) return error.TruncatedRecord;
    const end = header_len + header.stored_len;
    const checksum = std.mem.readInt(u32, bytes[end..][0..4], .little);
    if (checksum != crc.hash(bytes[0..end])) return error.ChecksumMismatch;
    return .{ .header = header, .value = bytes[header_len..end], .checksum = checksum, .len = end + 4 };
}

/// Writes the trailing checksum over a record whose header and value are already in place.
pub fn seal(bytes: []u8) u32 {
    const end = bytes.len - 4;
    const checksum = crc.hash(bytes[0..end]);
    std.mem.writeInt(u32, bytes[end..][0..4], checksum, .little);
    return checksum;
}

test "headers round trip and reject bad lengths" {
    const header: Header = .{ .slot = 1023, .local = 0x2f7c, .compression = .lz4, .stored_len = 5, .raw_len = 9 };
    var bytes: [header_len]u8 = undefined;
    header.write(&bytes);
    try std.testing.expectEqual(header, try Header.read(&bytes));

    const bad: Header = .{ .slot = 0, .local = 0x2c80, .stored_len = 3, .raw_len = 4 };
    bad.write(&bytes);
    try std.testing.expectError(error.InvalidLength, Header.read(&bytes));
}
