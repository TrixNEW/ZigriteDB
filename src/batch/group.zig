const std = @import("std");
const WriteBatch = @import("write.zig").WriteBatch;
const commit = @import("commit.zig");

pub const max_batches = 64;

pub fn validate(batches: []const WriteBatch) !void {
    if (batches.len == 0 or batches.len > max_batches) return error.InvalidArgument;
    var records: usize = 0;
    var bytes: usize = 0;
    var previous: u64 = 0;
    for (batches) |batch| {
        bytes = try std.math.add(usize, bytes, try batch.size());
        records = try std.math.add(usize, records, batch.entries.len);
        if (records > commit.max_records or bytes > commit.max_bytes) return error.BatchTooLarge;
        const first = batch.entries[0];
        if (first.header.batch_id <= previous) return error.BatchOrder;
        if (!std.meta.eql(first.key.region(), batches[0].entries[0].key.region())) return error.RegionMismatch;
        previous = first.header.batch_id;
    }
}
