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
        window: []u8 = &.{},
        window_start: usize = 0,
        window_len: usize = 0,

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

        /// Records use scratch until the next call, which must pass the same scratch.
        pub fn next(self: *Self, scratch: []u8) !?recovery.Batch {
            if (self.finished) return null;

            if (self.offset == self.length) {
                self.finished = true;
                return null;
            }

            if (scratch.len <= segment.encoded_len) return error.BufferTooSmall;

            while (true) {
                const in_window = scratch.ptr == self.window.ptr and scratch.len == self.window.len and
                    self.offset >= self.window_start and self.offset < self.window_start + self.window_len;
                if (!in_window) try self.refill(scratch);

                var scanner: recovery.Scanner = .{
                    .bytes = scratch[0 .. segment.encoded_len + self.window_len],
                    .header = self.header,
                    .mode = .active,
                    .offset = segment.encoded_len + self.offset - self.window_start,
                    .last_batch_id = self.last_batch_id,
                };
                if (try scanner.next()) |batch| {
                    const end = self.window_start + batch.end_offset - segment.encoded_len;
                    self.offset = end;
                    self.last_batch_id = batch.id;
                    return .{ .id = batch.id, .records = batch.records, .end_offset = end };
                }

                if (self.window_start + self.window_len == self.length) {
                    if (self.mode == .sealed) return error.IncompleteBatch;
                    self.has_tail = true;
                    self.finished = true;
                    return null;
                }
                if (self.window_start == self.offset) return error.BufferTooSmall;
                try self.refill(scratch);
            }
        }

        fn refill(self: *Self, scratch: []u8) !void {
            const len = @min(scratch.len - segment.encoded_len, self.length - self.offset);
            try self.device.readExact(scratch[segment.encoded_len..][0..len], self.offset);
            self.window = scratch;
            self.window_start = self.offset;
            self.window_len = len;
        }
    };
}
