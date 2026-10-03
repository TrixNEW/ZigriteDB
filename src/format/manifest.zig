const std = @import("std");
const crc = @import("crc.zig");

const Region = @import("key.zig").Region;

pub const header_len = 64;
pub const version = 2;
pub const max_segments = 4096;
pub const max_encoded_len = header_len + max_segments * 8 + 4;

pub const Error = error{
    TruncatedManifest,
    InvalidMagic,
    UnsupportedVersion,
    InvalidFlags,
    ChecksumMismatch,
    InvalidGeneration,
    InvalidSegmentCount,
    InvalidSegmentId,
    InvalidSegmentOrder,
    InvalidActiveSegment,
    InvalidLength,
    BufferTooSmall,
};

/// Sorted IDs; the last one is active.
pub const Manifest = struct {
    generation: u64,
    region: Region,
    segments: []const u64,
    /// Shared by the generation's base frames.
    base_batch_id: u64 = 0,
    salt: u64,

    /// `output` must not overlap `segments`.
    pub fn encode(self: Manifest, output: []u8) Error![]u8 {
        if (self.generation == 0) return error.InvalidGeneration;
        const len = try encodedSize(self.segments.len);
        var previous: u64 = 0;
        for (self.segments) |id| {
            try validateId(id, previous);
            previous = id;
        }
        if (output.len < len) return error.BufferTooSmall;

        const bytes = output[0..len];
        @memset(bytes[0..header_len], 0);
        @memcpy(bytes[0..4], "ZGMF");
        std.mem.writeInt(u16, bytes[4..6], version, .little);
        std.mem.writeInt(u64, bytes[8..16], self.generation, .little);
        std.mem.writeInt(i32, bytes[16..20], self.region.dimension, .little);
        std.mem.writeInt(i32, bytes[20..24], self.region.x, .little);
        std.mem.writeInt(i32, bytes[24..28], self.region.z, .little);
        std.mem.writeInt(u32, bytes[28..32], @intCast(self.segments.len), .little);
        std.mem.writeInt(u64, bytes[32..40], previous, .little);
        std.mem.writeInt(u64, bytes[40..48], self.base_batch_id, .little);
        std.mem.writeInt(u64, bytes[48..56], self.salt, .little);
        std.mem.writeInt(u32, bytes[60..64], crc.hash(bytes[0..60]), .little);
        for (self.segments, 0..) |id, i| std.mem.writeInt(u64, bytes[header_len + i * 8 ..][0..8], id, .little);
        std.mem.writeInt(u32, bytes[len - 4 ..][0..4], crc.hash(bytes[0 .. len - 4]), .little);
        return bytes;
    }
};

/// `segment_ids` must not overlap `bytes`; errors leave it unchanged.
pub fn decode(bytes: []const u8, segment_ids: []u64) Error!Manifest {
    if (bytes.len < header_len) return error.TruncatedManifest;
    if (!std.mem.eql(u8, bytes[0..4], "ZGMF")) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.UnsupportedVersion;
    if (std.mem.readInt(u32, bytes[60..64], .little) != crc.hash(bytes[0..60])) return error.ChecksumMismatch;
    if (std.mem.readInt(u16, bytes[6..8], .little) != 0 or std.mem.readInt(u32, bytes[56..60], .little) != 0) return error.InvalidFlags;

    const generation = std.mem.readInt(u64, bytes[8..16], .little);
    if (generation == 0) return error.InvalidGeneration;
    const count = std.mem.readInt(u32, bytes[28..32], .little);
    const len = try encodedSize(count);
    if (bytes.len < len) return error.TruncatedManifest;
    if (bytes.len != len) return error.InvalidLength;
    if (std.mem.readInt(u32, bytes[len - 4 ..][0..4], .little) != crc.hash(bytes[0 .. len - 4])) return error.ChecksumMismatch;

    var previous: u64 = 0;
    for (0..count) |i| {
        const id = readId(bytes, i);
        try validateId(id, previous);
        previous = id;
    }
    if (std.mem.readInt(u64, bytes[32..40], .little) != previous) return error.InvalidActiveSegment;
    if (segment_ids.len < count) return error.BufferTooSmall;
    for (segment_ids[0..count], 0..) |*id, i| id.* = readId(bytes, i);

    return .{
        .generation = generation,
        .region = .{
            .dimension = std.mem.readInt(i32, bytes[16..20], .little),
            .x = std.mem.readInt(i32, bytes[20..24], .little),
            .z = std.mem.readInt(i32, bytes[24..28], .little),
        },
        .segments = segment_ids[0..count],
        .base_batch_id = std.mem.readInt(u64, bytes[40..48], .little),
        .salt = std.mem.readInt(u64, bytes[48..56], .little),
    };
}

pub fn peekVersion(bytes: []const u8) ?u16 {
    if (bytes.len < 6 or !std.mem.eql(u8, bytes[0..4], "ZGMF")) return null;
    return std.mem.readInt(u16, bytes[4..6], .little);
}

pub fn encodedSize(count: usize) Error!usize {
    if (count == 0 or count > max_segments) return error.InvalidSegmentCount;
    return header_len + count * 8 + 4;
}

fn readId(bytes: []const u8, index: usize) u64 {
    return std.mem.readInt(u64, bytes[header_len + index * 8 ..][0..8], .little);
}

fn validateId(id: u64, previous: u64) Error!void {
    if (id == 0) return error.InvalidSegmentId;
    if (id <= previous) return error.InvalidSegmentOrder;
}
