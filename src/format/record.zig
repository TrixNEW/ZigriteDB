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

        const checksum = Crc32c.hash(bytes[0..28]);
        std.mem.writeInt(u32, bytes[28..32], checksum, .little);

        return bytes;
    }

    pub fn decode(bytes: []const u8) Error!Header {
        if (bytes.len < encoded_len) return error.TruncatedHeader;
        if (!std.mem.eql(u8, bytes[0..4], "ZGRC")) return error.InvalidMagic;
        if (bytes[4] != 1) return error.UnsupportedVersion;

        const expected_checksum = std.mem.readInt(u32, bytes[28..32], .little);
        const actual_checksum = Crc32c.hash(bytes[0..28]);

        if (expected_checksum != actual_checksum) return error.ChecksumMismatch;

        const reserved = std.mem.readInt(u32, bytes[24..28], .little);
        if (bytes[7] != 0 or reserved != 0) return error.InvalidFlags;

        const kind = std.enums.fromInt(Kind, bytes[5]) orelse return error.UnknownKind;
        const compression = std.enums.fromInt(Compression, bytes[6]) orelse return error.UnsupportedCompression;

        const header: Header = .{
            .kind = kind,
            .compression = compression,
            .stored_len = std.mem.readInt(u32, bytes[8..12], .little),
            .raw_len = std.mem.readInt(u32, bytes[12..16], .little),
            .batch_id = std.mem.readInt(u64, bytes[16..24], .little),
        };

        try header.validate();

        return header;
    }

    fn validate(self: Header) Error!void {
        if (self.batch_id == 0) return error.InvalidBatchId;

        const value_too_large =
            self.stored_len > max_value_len or
            self.raw_len > max_value_len;

        if (value_too_large) return error.InvalidLength;

        if (self.kind != .put) {
            const has_value = self.stored_len != 0 or self.raw_len != 0;
            if (self.compression != .none or has_value) return error.InvalidLength;

            return;
        }

        switch (self.compression) {
            .none => {
                if (self.stored_len != self.raw_len) return error.InvalidLength;
            },
            .lz4 => {
                const invalid_length = self.stored_len == 0 or self.stored_len >= self.raw_len;
                if (invalid_length) return error.InvalidLength;
            },
        }
    }
};
