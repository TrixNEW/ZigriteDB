const std = @import("std");
const Region = @import("key.zig").Region;
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const encoded_len = 48;
pub const version: u16 = 1;

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
        std.mem.writeInt(u32, bytes[44..48], Crc32c.hash(bytes[0..44]), .little);
        return bytes;
    }

    pub fn decode(bytes: []const u8) Error!Header {
        if (bytes.len < encoded_len) return error.TruncatedHeader;
        if (!std.mem.eql(u8, bytes[0..4], "ZGSG")) return error.InvalidMagic;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version)
            return error.UnsupportedVersion;
        if (std.mem.readInt(u32, bytes[44..48], .little) != Crc32c.hash(bytes[0..44]))
            return error.ChecksumMismatch;
        if (std.mem.readInt(u16, bytes[6..8], .little) != 0 or
            std.mem.readInt(u64, bytes[36..44], .little) != 0)
            return error.InvalidFlags;

        const header: Header = .{
            .segment_id = std.mem.readInt(u64, bytes[8..16], .little),
            .generation = std.mem.readInt(u64, bytes[16..24], .little),
            .region = .{
                .dimension = std.mem.readInt(i32, bytes[24..28], .little),
                .x = std.mem.readInt(i32, bytes[28..32], .little),
                .z = std.mem.readInt(i32, bytes[32..36], .little),
            },
        };
        try header.validate();
        return header;
    }

    pub fn checkIdentity(self: Header, expected: Header) Error!void {
        try self.validate();
        try expected.validate();
        if (self.segment_id != expected.segment_id or
            self.generation != expected.generation or
            self.region.dimension != expected.region.dimension or
            self.region.x != expected.region.x or
            self.region.z != expected.region.z)
            return error.IdentityMismatch;
    }

    fn validate(self: Header) Error!void {
        if (self.segment_id == 0) return error.InvalidSegmentId;
        if (self.generation == 0) return error.InvalidGeneration;
    }
};
