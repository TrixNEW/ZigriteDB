const std = @import("std");
const crc = @import("crc.zig");

const Region = @import("key.zig").Region;

/// Segment header, followed by frames without padding.
///
///   0  "ZGSG"   4 u16 version   6 u16 flags   8 u64 segment ID   16 u64 generation
///  24  i32 dimension, X, Z      36 u64 region salt               44 u32 CRC-32C of 0..44
pub const encoded_len = 48;
pub const version = 2;

pub const Error = error{
    TruncatedHeader,
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    InvalidFlags,
    InvalidSegmentId,
    InvalidGeneration,
    IdentityMismatch,
};

pub const Header = struct {
    segment_id: u64,
    generation: u64,
    region: Region,
    salt: u64,

    pub fn encode(self: Header) Error![encoded_len]u8 {
        try self.validate();
        var bytes = [_]u8{0} ** encoded_len;
        @memcpy(bytes[0..4], "ZGSG");
        std.mem.writeInt(u16, bytes[4..6], version, .little);
        std.mem.writeInt(u64, bytes[8..16], self.segment_id, .little);
        std.mem.writeInt(u64, bytes[16..24], self.generation, .little);
        std.mem.writeInt(i32, bytes[24..28], self.region.dimension, .little);
        std.mem.writeInt(i32, bytes[28..32], self.region.x, .little);
        std.mem.writeInt(i32, bytes[32..36], self.region.z, .little);
        std.mem.writeInt(u64, bytes[36..44], self.salt, .little);
        std.mem.writeInt(u32, bytes[44..48], crc.hash(bytes[0..44]), .little);
        return bytes;
    }

    pub fn decode(bytes: []const u8) Error!Header {
        if (bytes.len < encoded_len) return error.TruncatedHeader;
        if (!std.mem.eql(u8, bytes[0..4], "ZGSG")) return error.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, bytes[44..48], .little) != crc.hash(bytes[0..44])) return error.ChecksumMismatch;
        if (std.mem.readInt(u16, bytes[6..8], .little) != 0) return error.InvalidFlags;
        const header: Header = .{
            .segment_id = std.mem.readInt(u64, bytes[8..16], .little),
            .generation = std.mem.readInt(u64, bytes[16..24], .little),
            .region = .{
                .dimension = std.mem.readInt(i32, bytes[24..28], .little),
                .x = std.mem.readInt(i32, bytes[28..32], .little),
                .z = std.mem.readInt(i32, bytes[32..36], .little),
            },
            .salt = std.mem.readInt(u64, bytes[36..44], .little),
        };
        try header.validate();
        return header;
    }

    /// The salt is not known from the manifest, so it is compared only when `expected` sets one.
    pub fn checkIdentity(self: Header, expected: Header) Error!void {
        const mismatch = self.segment_id != expected.segment_id or self.generation != expected.generation or
            !self.region.eql(expected.region) or (expected.salt != 0 and self.salt != expected.salt);
        if (mismatch) return error.IdentityMismatch;
    }

    fn validate(self: Header) Error!void {
        if (self.segment_id == 0) return error.InvalidSegmentId;
        if (self.generation == 0) return error.InvalidGeneration;
    }
};

/// A per-region salt; never zero so it always takes part in identity checks.
pub fn newSalt(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little) | 1;
}
