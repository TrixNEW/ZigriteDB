const std = @import("std");
const crc = @import("crc.zig");
const index_module = @import("../index/index.zig");
const Location = index_module.Location;
const record = @import("record.zig");

// Index snapshot written on clean close. Never synced; ignored on any mismatch.
pub const name = "INDEX";
pub const header_len = 64;
pub const version = 1;
pub const entry_len = 24;

pub const Header = struct {
    fingerprints: bool,
    generation: u64,
    salt: u64,
    segments: u32,
    entries: u32,
    offset: u64,
    last_batch_id: u64,
    total_bytes: u64,
    seen_batch: bool,

    pub fn write(self: Header, bytes: *[header_len]u8) void {
        @memset(bytes, 0);
        @memcpy(bytes[0..4], "ZGIX");
        std.mem.writeInt(u16, bytes[4..6], version, .little);
        std.mem.writeInt(u16, bytes[6..8], @intFromBool(self.fingerprints), .little);
        std.mem.writeInt(u64, bytes[8..16], self.generation, .little);
        std.mem.writeInt(u64, bytes[16..24], self.salt, .little);
        std.mem.writeInt(u32, bytes[24..28], self.segments, .little);
        std.mem.writeInt(u32, bytes[28..32], self.entries, .little);
        std.mem.writeInt(u64, bytes[32..40], self.offset, .little);
        std.mem.writeInt(u64, bytes[40..48], self.last_batch_id, .little);
        std.mem.writeInt(u64, bytes[48..56], self.total_bytes, .little);
        bytes[56] = @intFromBool(self.seen_batch);
        std.mem.writeInt(u32, bytes[60..64], crc.hash(bytes[0..60]), .little);
    }

    pub fn read(bytes: *const [header_len]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..4], "ZGIX")) return error.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, bytes[60..64], .little) != crc.hash(bytes[0..60])) return error.ChecksumMismatch;
        const flags = std.mem.readInt(u16, bytes[6..8], .little);
        if (flags > 1 or bytes[56] > 1 or !std.mem.allEqual(u8, bytes[57..60], 0)) return error.InvalidFlags;
        return .{
            .fingerprints = flags == 1,
            .generation = std.mem.readInt(u64, bytes[8..16], .little),
            .salt = std.mem.readInt(u64, bytes[16..24], .little),
            .segments = std.mem.readInt(u32, bytes[24..28], .little),
            .entries = std.mem.readInt(u32, bytes[28..32], .little),
            .offset = std.mem.readInt(u64, bytes[32..40], .little),
            .last_batch_id = std.mem.readInt(u64, bytes[40..48], .little),
            .total_bytes = std.mem.readInt(u64, bytes[48..56], .little),
            .seen_batch = bytes[56] == 1,
        };
    }

    pub fn len(self: Header) usize {
        return header_len + @as(usize, self.segments) * 8 + 1024 * 2 + @as(usize, self.entries) * self.entryLen() + 4;
    }

    pub fn entryLen(self: Header) usize {
        return entry_len + @as(usize, if (self.fingerprints) 4 else 0);
    }
};

pub fn writeEntry(bytes: []u8, local: u16, location: Location, fingerprints: bool) void {
    std.mem.writeInt(u16, bytes[0..2], local, .little);
    bytes[2] = location.segment;
    bytes[3] = @intFromEnum(location.compression);
    std.mem.writeInt(u32, bytes[4..8], location.offset, .little);
    std.mem.writeInt(u32, bytes[8..12], location.stored_len, .little);
    std.mem.writeInt(u32, bytes[12..16], location.raw_len, .little);
    std.mem.writeInt(u64, bytes[16..24], location.batch_id, .little);
    if (fingerprints) std.mem.writeInt(u32, bytes[24..28], location.fingerprint, .little);
}

pub fn readEntry(bytes: []const u8, fingerprints: bool) !struct { u16, Location } {
    if (bytes[3] > 1) return error.InvalidFlags;
    const compression: record.Compression = @enumFromInt(bytes[3]);
    const location: Location = .{
        .segment = bytes[2],
        .compression = compression,
        .offset = std.mem.readInt(u32, bytes[4..8], .little),
        .stored_len = std.mem.readInt(u32, bytes[8..12], .little),
        .raw_len = std.mem.readInt(u32, bytes[12..16], .little),
        .batch_id = std.mem.readInt(u64, bytes[16..24], .little),
        .fingerprint = if (fingerprints) std.mem.readInt(u32, bytes[24..28], .little) else 0,
    };
    const valid = location.stored_len <= record.max_value_len and location.raw_len <= record.max_value_len and
        location.batch_id != 0 and switch (compression) {
        .none => location.stored_len == location.raw_len,
        .lz4 => location.stored_len != 0 and location.stored_len < location.raw_len,
    };
    if (!valid) return error.InvalidLength;
    return .{ std.mem.readInt(u16, bytes[0..2], .little), location };
}
