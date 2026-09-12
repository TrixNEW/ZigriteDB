const std = @import("std");
const Crc32c = std.hash.crc.Crc32Iscsi;

pub const encoded_len = 32;
pub const max_value_len = 16 * 1024 * 1024;

pub const Kind = enum(u8) {
    put = 1,
    delete = 2,
    commit = 3,
};

pub const Compression = enum(u8) {
    none = 0,
    lz4 = 1,
};

pub const Error = error{
    TruncatedHeader,
    InvalidMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    UnknownKind,
    UnsupportedCompression,
    InvalidFlags,
    InvalidLength,
    InvalidBatchId,
};

pub const Header = struct {
    kind: Kind,
    compression: Compression = .none,
    stored_len: u32 = 0,
    raw_len: u32 = 0,
    batch_id: u64,

    pub fn encode(self: Header) Error![encoded_len]u8 {
        try self.validate();
        var bytes = [_]u8{0} ** encoded_len;
        @memcpy(bytes[0..4], "ZGRC");
        bytes[4] = 1;
        bytes[5] = @intFromEnum(self.kind);
        bytes[6] = @intFromEnum(self.compression);
        std.mem.writeInt(u32, bytes[8..12], self.stored_len, .little);
        std.mem.writeInt(u32, bytes[12..16], self.raw_len, .little);
        std.mem.writeInt(u64, bytes[16..24], self.batch_id, .little);
        std.mem.writeInt(u32, bytes[28..32], Crc32c.hash(bytes[0..28]), .little);
        return bytes;
    }

    /// Reads one header prefix without allocating.
    pub fn decode(bytes: []const u8) Error!Header {
        if (bytes.len < encoded_len) return error.TruncatedHeader;
        if (!std.mem.eql(u8, bytes[0..4], "ZGRC")) return error.InvalidMagic;
        if (bytes[4] != 1) return error.UnsupportedVersion;
        if (std.mem.readInt(u32, bytes[28..32], .little) != Crc32c.hash(bytes[0..28]))
            return error.ChecksumMismatch;
        if (bytes[7] != 0 or std.mem.readInt(u32, bytes[24..28], .little) != 0)
            return error.InvalidFlags;
        const header: Header = .{
            .kind = std.enums.fromInt(Kind, bytes[5]) orelse return error.UnknownKind,
            .compression = std.enums.fromInt(Compression, bytes[6]) orelse return error.UnsupportedCompression,
            .stored_len = std.mem.readInt(u32, bytes[8..12], .little),
            .raw_len = std.mem.readInt(u32, bytes[12..16], .little),
            .batch_id = std.mem.readInt(u64, bytes[16..24], .little),
        };
        try header.validate();
        return header;
    }

    fn validate(self: Header) Error!void {
        if (self.batch_id == 0) return error.InvalidBatchId;
        if (self.stored_len > max_value_len or self.raw_len > max_value_len)
            return error.InvalidLength;
        if (self.kind != .put) {
            if (self.compression != .none or self.stored_len != 0 or self.raw_len != 0)
                return error.InvalidLength;
        } else switch (self.compression) {
            .none => if (self.stored_len != self.raw_len) return error.InvalidLength,
            .lz4 => if (self.stored_len == 0 or self.stored_len >= self.raw_len) return error.InvalidLength,
        }
    }
};
