const std = @import("std");

const frame = @import("../format/frame.zig");
const key_format = @import("../format/key.zig");
const Key = key_format.Key;
const Region = key_format.Region;
const record = @import("../format/record.zig");

pub const max_group_batches = 64;

pub const Entry = struct {
    key: Key,
    /// Null deletes the key.
    value: ?[]const u8,

    pub fn put(key: Key, value: []const u8) Entry {
        return .{ .key = key, .value = value };
    }

    pub fn delete(key: Key) Entry {
        return .{ .key = key, .value = null };
    }
};

pub const WriteBatch = struct {
    /// Zero takes the next ID.
    id: u64 = 0,
    entries: []const Entry,

    pub fn region(self: WriteBatch) Region {
        return self.entries[0].key.region();
    }

    pub fn validate(self: WriteBatch) !usize {
        if (self.entries.len == 0) return error.EmptyBatch;
        if (self.entries.len > frame.max_records) return error.BatchTooLarge;
        const first = self.region();
        var size: usize = frame.header_len;
        for (self.entries) |entry| {
            try entry.key.validate();
            if (!entry.key.region().eql(first)) return error.RegionMismatch;
            const len = if (entry.value) |value| value.len else 0;
            if (len > record.max_value_len) return error.BatchTooLarge;
            size += record.overhead + len;
        }
        if (size - frame.header_len > frame.max_bytes) return error.BatchTooLarge;
        return size;
    }

    pub fn bound(self: WriteBatch) usize {
        var size: usize = frame.header_len;
        for (self.entries) |entry| size += frame.Builder.bound(if (entry.value) |value| value.len else 0);
        return size;
    }
};

pub fn validateGroup(batches: []const WriteBatch) !usize {
    if (batches.len == 0 or batches.len > max_group_batches) return error.InvalidArgument;
    var size: usize = 0;
    var records: usize = 0;
    var previous: u64 = 0;
    for (batches) |batch| {
        size += try batch.validate();
        records += batch.entries.len;
        if (records > frame.max_records or size > frame.max_bytes) return error.BatchTooLarge;
        if (!batch.region().eql(batches[0].region())) return error.RegionMismatch;
        if (batch.id != 0) {
            if (batch.id <= previous) return error.BatchOrder;
            previous = batch.id;
        }
    }
    return size;
}
