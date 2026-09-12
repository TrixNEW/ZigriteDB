const std = @import("std");
const Region = @import("key.zig").Region;
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const header_len = 48;
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

/// Segment IDs use your buffer and must be sorted, with the active segment last.
pub const Manifest = struct {
    generation: u64,
    region: Region,
    segments: []const u64,

    /// Keep the output buffer separate from segments. Errors leave it unchanged.
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
        std.mem.writeInt(u16, bytes[4..6], 1, .little);
        std.mem.writeInt(u64, bytes[8..16], self.generation, .little);
        std.mem.writeInt(i32, bytes[16..20], self.region.dimension, .little);
        std.mem.writeInt(i32, bytes[20..24], self.region.x, .little);
        std.mem.writeInt(i32, bytes[24..28], self.region.z, .little);
        std.mem.writeInt(u32, bytes[28..32], @intCast(self.segments.len), .little);
        std.mem.writeInt(u64, bytes[32..40], previous, .little);
        std.mem.writeInt(u32, bytes[44..48], Crc32c.hash(bytes[0..44]), .little);
        for (self.segments, 0..) |id, index| {
            const offset = header_len + index * 8;
            std.mem.writeInt(u64, bytes[offset..][0..8], id, .little);
        }
        std.mem.writeInt(u32, bytes[len - 4 ..][0..4], Crc32c.hash(bytes[0 .. len - 4]), .little);
        return bytes;
    }
};

/// Keep segment_ids separate from bytes. Errors leave segment_ids unchanged.
pub fn decode(bytes: []const u8, segment_ids: []u64) Error!Manifest {
    if (bytes.len < header_len) return error.TruncatedManifest;
    if (!std.mem.eql(u8, bytes[0..4], "ZGMF")) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != 1) return error.UnsupportedVersion;
    if (std.mem.readInt(u32, bytes[44..48], .little) != Crc32c.hash(bytes[0..44]))
        return error.ChecksumMismatch;
    if (std.mem.readInt(u16, bytes[6..8], .little) != 0 or
        std.mem.readInt(u32, bytes[40..44], .little) != 0)
        return error.InvalidFlags;

    const generation = std.mem.readInt(u64, bytes[8..16], .little);
    if (generation == 0) return error.InvalidGeneration;
    const count = std.mem.readInt(u32, bytes[28..32], .little);
    const len = try encodedSize(count);
    if (bytes.len < len) return error.TruncatedManifest;
    if (bytes.len != len) return error.InvalidLength;
    if (std.mem.readInt(u32, bytes[len - 4 ..][0..4], .little) != Crc32c.hash(bytes[0 .. len - 4]))
        return error.ChecksumMismatch;

    var previous: u64 = 0;
    for (0..count) |index| {
        const id = readId(bytes, index);
        try validateId(id, previous);
        previous = id;
    }
    if (std.mem.readInt(u64, bytes[32..40], .little) != previous)
        return error.InvalidActiveSegment;
    if (segment_ids.len < count) return error.BufferTooSmall;

    const region: Region = .{
        .dimension = std.mem.readInt(i32, bytes[16..20], .little),
        .x = std.mem.readInt(i32, bytes[20..24], .little),
        .z = std.mem.readInt(i32, bytes[24..28], .little),
    };
    for (segment_ids[0..count], 0..) |*id, index| id.* = readId(bytes, index);
    return .{ .generation = generation, .region = region, .segments = segment_ids[0..count] };
}

fn encodedSize(count: usize) Error!usize {
    if (count == 0 or count > max_segments) return error.InvalidSegmentCount;
    const payload_len = std.math.mul(usize, count, 8) catch return error.InvalidLength;
    return std.math.add(usize, header_len + 4, payload_len) catch error.InvalidLength;
}

fn readId(bytes: []const u8, index: usize) u64 {
    const offset = header_len + index * 8;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn validateId(id: u64, previous: u64) Error!void {
    if (id == 0) return error.InvalidSegmentId;
    if (id <= previous) return error.InvalidSegmentOrder;
}
