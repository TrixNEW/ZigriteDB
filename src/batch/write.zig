const std = @import("std");

const Entry = @import("../format/entry.zig").Entry;
const commit = @import("commit.zig");

pub const WriteBatch = struct {
    entries: []const Entry,

    pub fn size(self: WriteBatch) commit.Error!usize {
        if (self.entries.len == 0) return error.EmptyBatch;
        if (self.entries.len > commit.max_records) return error.BatchTooLarge;

        const first = &self.entries[0];
        const region = first.key.region();

        var bytes: usize = 0;

        for (self.entries) |item| {
            const len = try item.size();

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

    /// `output` must not overlap the entries or their values!!
    pub fn encode(self: WriteBatch, output: []u8) commit.Error![]u8 {
        const len = try self.size();
        if (output.len < len) return error.BufferTooSmall;

        var offset: usize = 0;

        for (self.entries) |item| {
            const bytes = try item.encode(output[offset..len]);
            offset += bytes.len;
        }

        const marker = try commit.seal(output[0..offset]);
        @memcpy(output[offset..len], &marker);

        return output[0..len];
    }
};
