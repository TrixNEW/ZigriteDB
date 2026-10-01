const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const lz4 = @import("../compression/lz4.zig");
const Entry = @import("../format/entry.zig").Entry;
const commit = @import("commit.zig");

pub const WriteBatch = struct {
    entries: []const Entry,

    /// Leaves compressed values unchecked; `validate` and `encode` check them.
    pub fn size(self: WriteBatch) commit.Error!usize {
        if (self.entries.len == 0) return error.EmptyBatch;
        if (self.entries.len > commit.max_records) return error.BatchTooLarge;

        const first = &self.entries[0];
        const region = first.key.region();

        var bytes: usize = 0;

        for (self.entries) |item| {
            const len = try item.encodedLen();

            if (item.header.batch_id != first.header.batch_id) return error.BatchIdMismatch;

            const current = item.key.region();
            const same_region =
                current.dimension == region.dimension and
                current.x == region.x and
                current.z == region.z;

            if (!same_region) return error.RegionMismatch;

            bytes = std.math.add(usize, bytes, len) catch return error.BatchTooLarge;
            if (bytes > commit.max_bytes) return error.BatchTooLarge;
        }

        return std.math.add(usize, bytes, commit.commit_len) catch error.BatchTooLarge;
    }

    pub fn validate(self: WriteBatch) commit.Error!usize {
        const len = try self.size();
        for (self.entries) |item| {
            if (item.header.compression == .lz4) try lz4.validate(item.value, item.header.raw_len);
        }
        return len;
    }

    pub fn id(self: WriteBatch) u64 {
        return self.entries[0].header.batch_id;
    }

    /// `output` must not overlap the entries or their values.
    pub fn encode(self: WriteBatch, output: []u8) commit.Error![]u8 {
        _ = try self.validate();
        return self.encodeChecked(output);
    }

    /// `encode` for batches that already passed `validate`.
    pub fn encodeChecked(self: WriteBatch, output: []u8) commit.Error![]u8 {
        const len = try self.size();
        if (output.len < len) return error.BufferTooSmall;

        var digest = Sha256.init(.{});
        var offset: usize = 0;
        for (self.entries) |item| {
            const bytes = try item.encodeChecked(output[offset..len]);
            digest.update(bytes);
            offset += bytes.len;
        }

        const marker = try commit.marker(self.id(), @intCast(self.entries.len), offset, digest.finalResult());
        @memcpy(output[offset..len], &marker);
        return output[0..len];
    }
};
