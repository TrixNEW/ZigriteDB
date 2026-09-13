const std = @import("std");

const commit = @import("../batch/commit.zig");
const entry = @import("../format/entry.zig");
const record = @import("../format/record.zig");
const segment = @import("../format/segment.zig");
const recovery = @import("scan.zig");

pub fn Scanner(comptime Device: type) type {
    return struct {
        device: Device,
        header: segment.Header,
        mode: recovery.Mode,
        length: usize,
        offset: usize = segment.encoded_len,
        last_batch_id: u64,
        finished: bool = false,
        has_tail: bool = false,

        const Self = @This();

        pub fn init(device: Device, expected: segment.Header, mode: recovery.Mode, previous_id: u64, max_size: u64) !Self {
            const length = try device.length();

            if (length > max_size) return error.SegmentTooLarge;
            if (length < segment.encoded_len) return error.TruncatedHeader;

            var bytes: [segment.encoded_len]u8 = undefined;
            try device.readExact(&bytes, 0);

            const header = try segment.Header.decode(&bytes);
            try header.checkIdentity(expected);

            return .{
                .device = device,
                .header = header,
                .mode = mode,
                .length = std.math.cast(usize, length) orelse return error.InvalidLength,
                .last_batch_id = previous_id,
            };
        }

        /// Returned records use scratch until the next call.
        pub fn next(self: *Self, scratch: []u8) !?recovery.Batch {
            if (self.finished) return null;

            if (self.offset == self.length) {
                self.finished = true;
                return null;
            }

            if (scratch.len < segment.encoded_len) return error.BufferTooSmall;
            @memcpy(scratch[0..segment.encoded_len], &(try self.header.encode()));

            var used: usize = segment.encoded_len;
            var position = self.offset;
            var count: usize = 0;

            while (position < self.length) {
                const header_len = @min(record.encoded_len, self.length - position);
                if (scratch.len - used < header_len) return error.BufferTooSmall;

                try self.device.readExact(scratch[used..][0..header_len], position);
                if (header_len < record.encoded_len) return self.finish(scratch[0 .. used + header_len]);

                const header = try record.Header.decode(scratch[used..][0..header_len]);
                const is_commit = header.kind == .commit;
                const size = if (is_commit)
                    commit.commit_len
                else
                    try std.math.add(usize, entry.overhead, header.stored_len);

                if (!is_commit) {
                    if (count == commit.max_records) return error.BatchTooLarge;
                    const batch_size = try std.math.add(usize, used - segment.encoded_len, size);
                    if (batch_size > commit.max_bytes) return error.BatchTooLarge;
                    count += 1;
                }

                const available = @min(size, self.length - position);
                if (scratch.len - used < available) return error.BufferTooSmall;

                try self.device.readExact(
                    scratch[used + header_len ..][0 .. available - header_len],
                    position + header_len,
                );

                used += available;
                position += available;

                if (available < size or is_commit) return self.finish(scratch[0..used]);
            }

            return self.finish(scratch[0..used]);
        }

        fn finish(self: *Self, bytes: []const u8) !?recovery.Batch {
            var scanner = try recovery.Scanner.init(bytes, self.header, self.mode, self.last_batch_id);

            if (try scanner.next()) |batch| {
                const end = try std.math.add(usize, self.offset, batch.end_offset - segment.encoded_len);
                self.offset = end;
                self.last_batch_id = batch.id;

                return .{
                    .id = batch.id,
                    .records = batch.records,
                    .end_offset = end,
                };
            }

            self.has_tail = scanner.has_tail;
            self.finished = true;

            return null;
        }
    };
}
