const std = @import("std");
const segment = @import("../format/segment.zig");
const WriteBatch = @import("../batch/write.zig").WriteBatch;

pub const Durability = enum { sync, buffered };

pub const AppendResult = struct {
    batch_id: u64,
    start: u64,
    end: u64,
    synced: bool,
};

pub fn Writer(comptime Device: type) type {
    return struct {
        device: Device,
        header: segment.Header,
        max_size: u64,
        offset: u64 = segment.encoded_len,
        synced_offset: u64 = segment.encoded_len,
        last_batch_id: u64,
        failed: bool = false,

        const Self = @This();

        pub fn create(device: Device, header: segment.Header, max_size: u64, previous_batch_id: u64) !Self {
            const bytes = try header.encode();
            if (max_size < segment.encoded_len) return error.SegmentFull;
            if (try device.length() != 0) return error.FileNotEmpty;
            try device.writeAll(&bytes, 0);
            try device.sync();
            return .{
                .device = device,
                .header = header,
                .max_size = max_size,
                .last_batch_id = previous_batch_id,
            };
        }

        pub fn append(self: *Self, batch: WriteBatch, scratch: []u8, durability: Durability) !AppendResult {
            if (self.failed) return error.WriterFailed;
            const size = try batch.size();
            const id = batch.entries[0].header.batch_id;
            if (id <= self.last_batch_id) return error.BatchOrder;
            const region = batch.entries[0].key.region();
            if (region.dimension != self.header.region.dimension or
                region.x != self.header.region.x or region.z != self.header.region.z)
                return error.RegionMismatch;
            const end = std.math.add(u64, self.offset, size) catch return error.SegmentFull;
            if (end > self.max_size) return error.SegmentFull;
            const bytes = try batch.encode(scratch);

            self.device.writeAll(bytes, self.offset) catch |err| {
                self.failed = true;
                return err;
            };
            if (durability == .sync) {
                self.device.sync() catch |err| {
                    self.failed = true;
                    return err;
                };
            }

            const start = self.offset;
            self.offset = end;
            self.last_batch_id = id;
            if (durability == .sync) self.synced_offset = end;
            return .{ .batch_id = id, .start = start, .end = end, .synced = durability == .sync };
        }

        pub fn flush(self: *Self) !void {
            if (self.failed) return error.WriterFailed;
            if (self.synced_offset == self.offset) return;
            self.device.sync() catch |err| {
                self.failed = true;
                return err;
            };
            self.synced_offset = self.offset;
        }
    };
}
