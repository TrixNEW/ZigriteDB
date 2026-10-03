const std = @import("std");
const crc = @import("crc.zig");
const lz4 = @import("../compression/lz4.zig");
const record = @import("record.zig");

/// A frame holds one atomic batch of records from a single region.
///
///   0  u32  body length
///   4  u16  record count
///   6  u8   kind
///   7  u8   zero
///   8  u64  batch ID
///  16  u32  CRC-32C over the records' own checksums, in order
///  20  u32  CRC-32C of the region salt and bytes 0..20
///
/// A frame counts only when its header and every record verify, so torn or
/// partial writes are never applied. The salt rejects stale frames left by
/// other regions' deleted files.
pub const header_len = 24;
pub const max_records = 4096;
pub const max_bytes = 64 * 1024 * 1024;

pub const Kind = enum(u8) {
    /// An atomic write.
    batch = 1,
    /// Compaction output; every base frame of a generation shares one ID.
    base = 2,
};

pub const Error = record.Error || error{
    TruncatedFrame,
    InvalidFrame,
    BatchMismatch,
};

pub const Header = struct {
    body_len: u32,
    count: u16,
    kind: Kind = .batch,
    batch_id: u64,
    body_crc: u32,

    pub fn write(self: Header, salt: u64, bytes: *[header_len]u8) void {
        std.mem.writeInt(u32, bytes[0..4], self.body_len, .little);
        std.mem.writeInt(u16, bytes[4..6], self.count, .little);
        bytes[6] = @intFromEnum(self.kind);
        bytes[7] = 0;
        std.mem.writeInt(u64, bytes[8..16], self.batch_id, .little);
        std.mem.writeInt(u32, bytes[16..20], self.body_crc, .little);
        std.mem.writeInt(u32, bytes[20..24], headerChecksum(salt, bytes[0..20]), .little);
    }

    pub fn read(bytes: *const [header_len]u8, salt: u64) Error!Header {
        if (std.mem.readInt(u32, bytes[20..24], .little) != headerChecksum(salt, bytes[0..20])) return error.ChecksumMismatch;
        const header: Header = .{
            .body_len = std.mem.readInt(u32, bytes[0..4], .little),
            .count = std.mem.readInt(u16, bytes[4..6], .little),
            .kind = std.enums.fromInt(Kind, bytes[6]) orelse return error.InvalidFrame,
            .batch_id = std.mem.readInt(u64, bytes[8..16], .little),
            .body_crc = std.mem.readInt(u32, bytes[16..20], .little),
        };
        const valid = bytes[7] == 0 and header.batch_id != 0 and header.count != 0 and header.count <= max_records and
            header.body_len >= @as(u32, header.count) * record.overhead and header.body_len <= max_bytes;
        if (!valid) return error.InvalidFrame;
        return header;
    }

    pub fn len(self: Header) usize {
        return header_len + @as(usize, self.body_len);
    }
};

fn headerChecksum(salt: u64, bytes: *const [20]u8) u32 {
    var salt_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &salt_bytes, salt, .little);
    return ~crc.update(crc.update(0xffff_ffff, &salt_bytes), bytes);
}

/// Checks a whole frame at the start of `bytes`, calling `visit(context, offset, decoded)`
/// for each record only after all of them verified. Returns the frame length.
pub fn verify(bytes: []const u8, salt: u64, context: anytype, comptime visit: anytype) (Error || VisitError(@TypeOf(visit)))!Header {
    if (bytes.len < header_len) return error.TruncatedFrame;
    const header = try Header.read(bytes[0..header_len], salt);
    if (bytes.len < header.len()) return error.TruncatedFrame;
    const body = bytes[header_len..header.len()];
    var offset: usize = 0;
    var checksums: u32 = 0xffff_ffff;
    for (0..header.count) |_| {
        if (offset == body.len) return error.BatchMismatch;
        const decoded = try record.decode(body[offset..]);
        var sum: [4]u8 = undefined;
        std.mem.writeInt(u32, &sum, decoded.checksum, .little);
        checksums = crc.update(checksums, &sum);
        offset += decoded.len;
    }
    if (offset != body.len or ~checksums != header.body_crc) return error.BatchMismatch;
    try each(body, context, visit);
    return header;
}

/// Walks records that were already verified, or that this process encoded.
pub fn each(body: []const u8, context: anytype, comptime visit: anytype) VisitError(@TypeOf(visit))!void {
    var offset: usize = 0;
    while (offset < body.len) {
        const header = record.Header.read(body[offset..][0..record.header_len]) catch unreachable;
        const result = visit(context, header_len + offset, header, body[offset + record.header_len ..][0..header.stored_len]);
        if (@typeInfo(@TypeOf(result)) == .error_union) try result;
        offset += record.overhead + header.stored_len;
    }
}

fn VisitError(comptime Visit: type) type {
    const result = @typeInfo(@typeInfo(Visit).@"fn".return_type.?);
    return if (result == .error_union) result.error_union.error_set else error{};
}

/// Encodes records straight into a caller buffer, compressing values on the way.
/// The header is written last by `finish`, so the batch ID can be picked under a lock.
pub const Builder = struct {
    buffer: []u8,
    len: usize = header_len,
    count: u16 = 0,
    checksums: u32 = 0xffff_ffff,

    pub fn init(buffer: []u8) Builder {
        return .{ .buffer = buffer };
    }

    /// Worst-case bytes `add` needs for a value of `len`.
    pub fn bound(len: usize) usize {
        return record.overhead + (lz4.bound(len) catch len);
    }

    pub fn add(self: *Builder, slot: u10, local: u16, value: ?[]const u8, encoder: ?*lz4.Encoder, threshold: usize) (lz4.Error || error{ BatchTooLarge, BufferTooSmall })!void {
        if (self.count == max_records) return error.BatchTooLarge;
        const raw = value orelse &.{};
        if (raw.len > record.max_value_len) return error.BatchTooLarge;
        const start = self.len;
        const room = self.buffer.len - start;
        if (room < record.overhead + raw.len) return error.BufferTooSmall;
        var head: record.Header = .{ .slot = slot, .local = local, .delete = value == null, .stored_len = @intCast(raw.len), .raw_len = @intCast(raw.len) };
        const payload = self.buffer[start + record.header_len ..];
        compressed: {
            const lz = encoder orelse break :compressed;
            if (raw.len < threshold or raw.len == 0 or room < bound(raw.len)) break :compressed;
            const out = try lz.compress(raw, payload[0..try lz4.bound(raw.len)]);
            if (out.len >= raw.len) break :compressed;
            head.compression = .lz4;
            head.stored_len = @intCast(out.len);
        }
        if (head.compression == .none) @memcpy(payload[0..raw.len], raw);
        head.write(self.buffer[start..][0..record.header_len]);
        const end = start + record.overhead + head.stored_len;
        const checksum = record.seal(self.buffer[start..end]);
        var sum: [4]u8 = undefined;
        std.mem.writeInt(u32, &sum, checksum, .little);
        self.checksums = crc.update(self.checksums, &sum);
        self.len = end;
        self.count += 1;
        if (self.len - header_len > max_bytes) return error.BatchTooLarge;
    }

    /// Copies an already sealed record, keeping its checksum.
    pub fn copy(self: *Builder, bytes: []const u8) error{ BatchTooLarge, BufferTooSmall }!void {
        if (self.count == max_records or self.len - header_len + bytes.len > max_bytes) return error.BatchTooLarge;
        if (self.buffer.len - self.len < bytes.len) return error.BufferTooSmall;
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.checksums = crc.update(self.checksums, bytes[bytes.len - 4 ..]);
        self.len += bytes.len;
        self.count += 1;
    }

    pub fn body(self: *const Builder) []const u8 {
        return self.buffer[header_len..self.len];
    }

    pub fn header(self: *const Builder, kind: Kind, batch_id: u64) Header {
        return .{
            .body_len = @intCast(self.len - header_len),
            .count = self.count,
            .kind = kind,
            .batch_id = batch_id,
            .body_crc = ~self.checksums,
        };
    }

    pub fn finish(self: *Builder, kind: Kind, batch_id: u64, salt: u64) []u8 {
        std.debug.assert(self.count != 0);
        self.header(kind, batch_id).write(salt, self.buffer[0..header_len]);
        return self.buffer[0..self.len];
    }

    pub fn reset(self: *Builder) void {
        self.len = header_len;
        self.count = 0;
        self.checksums = 0xffff_ffff;
    }
};

test "frames round trip, compress, and reject damage anywhere" {
    var buffer: [4096]u8 = undefined;
    var encoder: lz4.Encoder = .{};
    var builder: Builder = .init(&buffer);
    const repetitive = "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd";
    try builder.add(5, 0x2c80, "v", &encoder, 16);
    try builder.add(6, 0x2f7f, repetitive, &encoder, 16);
    try builder.add(7, 0x3180, null, &encoder, 16);
    const bytes = builder.finish(.batch, 9, 77);

    const Seen = struct {
        count: usize = 0,
        fn visit(self: *@This(), offset: usize, header: record.Header, value: []const u8) !void {
            _ = offset;
            if (self.count == 1) {
                try std.testing.expectEqual(record.Compression.lz4, header.compression);
                var out: [64]u8 = undefined;
                try std.testing.expectEqualStrings(repetitive, try lz4.decompress(value, &out, header.raw_len));
            }
            if (self.count == 2) try std.testing.expect(header.delete);
            self.count += 1;
        }
    };
    var seen: Seen = .{};
    const header = try verify(bytes, 77, &seen, Seen.visit);
    try std.testing.expectEqual(@as(u64, 9), header.batch_id);
    try std.testing.expectEqual(@as(usize, 3), seen.count);
    try std.testing.expectError(error.ChecksumMismatch, verify(bytes, 78, &seen, Seen.visit));
    try std.testing.expectError(error.TruncatedFrame, verify(bytes[0 .. bytes.len - 1], 77, &seen, Seen.visit));

    for (0..bytes.len) |i| {
        bytes[i] ^= 0x40;
        defer bytes[i] ^= 0x40;
        var ignored: Seen = .{};
        try std.testing.expect(std.meta.isError(verify(bytes, 77, &ignored, Seen.visit)));
        try std.testing.expectEqual(@as(usize, 0), ignored.count);
    }
}
