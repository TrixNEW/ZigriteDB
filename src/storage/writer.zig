pub const Durability = enum {
    sync,
    buffered,
};

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
            if (max_size < segment.encoded_len) return error.SegmentFull;
            if (try device.length() != 0) return error.FileNotEmpty;

            const bytes = try header.encode();

            try device.writeAll(&bytes, 0);
            try device.sync();

            return .{
                .device = device,
                .header = header,
                .max_size = max_size,
                .last_batch_id = previous_batch_id,
            };
        }

        pub fn reopen(device: Device, header: segment.Header, max_size: u64, previous_batch_id: u64, scratch: []u8) !Self {
            var scanner = try file_scan.Scanner(Device).init(device, header, .active, previous_batch_id, max_size);

            while (try scanner.next(scratch)) |_| {}

            if (scanner.has_tail) return error.NeedsRecovery;
            if (try device.length() != scanner.length) return error.FileChanged;

            try device.sync();

            return .{
                .device = device,
                .header = header,
                .max_size = max_size,
                .offset = scanner.offset,
                .synced_offset = scanner.offset,
                .last_batch_id = scanner.last_batch_id,
            };
        }
        pub fn append(self: *Self, batch: WriteBatch, scratch: []u8, durability: Durability) !AppendResult {
            if (self.failed) return error.WriterFailed;

            const bytes = try batch.encode(scratch);
            return self.appendEncoded(bytes, durability);
        }

        pub fn appendEncoded(self: *Self, bytes: []const u8, durability: Durability) !AppendResult {
            if (self.failed) return error.WriterFailed;
            if (bytes.len < commit.commit_len) return error.InvalidCommit;

            const records = bytes[0 .. bytes.len - commit.commit_len];
            try commit.verify(records, bytes[records.len..]);

            const first = try record_entry.decode(records);
            const id = first.entry.header.batch_id;
            const region = first.entry.key.region();

            if (id <= self.last_batch_id) return error.BatchOrder;

            const same_region =
                region.dimension == self.header.region.dimension and
                region.x == self.header.region.x and
                region.z == self.header.region.z;

            if (!same_region) return error.RegionMismatch;

            const end = std.math.add(u64, self.offset, bytes.len) catch return error.SegmentFull;
            if (end > self.max_size) return error.SegmentFull;
            self.device.writeAll(bytes, self.offset) catch |err| {
                self.failed = true;
                return err;
            };

            const should_sync = durability == .sync;

            if (should_sync) {
                self.device.sync() catch |err| {
                    self.failed = true;
                    return err;
                };
            }

            const start = self.offset;

            self.offset = end;
            self.last_batch_id = id;

            if (should_sync) self.synced_offset = end;

            return .{
                .batch_id = id,
                .start = start,
                .end = end,
                .synced = should_sync,
            };
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

const std = @import("std");

const commit = @import("../batch/commit.zig");
const WriteBatch = @import("../batch/write.zig").WriteBatch;
const record_entry = @import("../format/entry.zig");
const test_entry = @import("../format/entry.zig");
const segment = @import("../format/segment.zig");
const storage_file = @import("../io/file.zig");
const file_scan = @import("../recovery/file_scan.zig");
