const std = @import("std");

const frame = @import("../format/frame.zig");
const record = @import("../format/record.zig");
const segment = @import("../format/segment.zig");

pub const Error = frame.Error || segment.Error || error{
    IncompleteBatch,
    BatchOrder,
    BufferTooSmall,
    SegmentTooLarge,
};

/// Only the active segment may end in a torn tail.
pub const Mode = enum { sealed, active };

pub const Batch = struct {
    header: frame.Header,
    bytes: []const u8,
    offset: u64,

    pub fn end(self: Batch) u64 {
        return self.offset + self.bytes.len;
    }

    pub fn body(self: Batch) []const u8 {
        return self.bytes[frame.header_len..];
    }
};

pub const Order = struct {
    /// Starts at the manifest's base batch ID.
    last_batch_id: u64 = 0,
    /// Base frames may only open a generation.
    seen_batch: bool = false,

    pub fn accept(self: *Order, header: frame.Header) Error!void {
        switch (header.kind) {
            .base => if (self.seen_batch or header.batch_id != self.last_batch_id) return error.BatchOrder,
            .batch => {
                if (header.batch_id <= self.last_batch_id) return error.BatchOrder;
                self.seen_batch = true;
                self.last_batch_id = header.batch_id;
            },
        }
    }
};

const Step = union(enum) {
    batch: Batch,
    end,
    truncated,
    invalid: anyerror,
};

fn noop(_: void, _: usize, _: record.Header, _: []const u8) void {}

fn step(bytes: []const u8, base_offset: u64, salt: u64, order: *Order) Step {
    if (bytes.len == 0) return .end;
    const header = frame.verify(bytes, salt, {}, noop) catch |err| return switch (err) {
        error.TruncatedFrame => .truncated,
        else => .{ .invalid = err },
    };
    var next_order = order.*;
    next_order.accept(header) catch |err| return .{ .invalid = err };
    order.* = next_order;
    return .{ .batch = .{ .header = header, .bytes = bytes[0..header.len()], .offset = base_offset } };
}

pub const Scanner = struct {
    bytes: []const u8,
    header: segment.Header,
    mode: Mode,
    offset: usize = segment.encoded_len,
    order: Order,
    finished: bool = false,
    has_tail: bool = false,

    pub fn init(bytes: []const u8, expected: segment.Header, mode: Mode, order: Order) Error!Scanner {
        const header = try segment.Header.decode(bytes);
        try header.checkIdentity(expected);
        return .{ .bytes = bytes, .header = header, .mode = mode, .order = order };
    }

    /// Errors leave the scanner where it was.
    pub fn next(self: *Scanner) Error!?Batch {
        if (self.finished) return null;
        switch (step(self.bytes[self.offset..], self.offset, self.header.salt, &self.order)) {
            .batch => |batch| {
                self.offset += batch.bytes.len;
                return batch;
            },
            .end => {
                self.finished = true;
                return null;
            },
            .truncated => return self.tail(error.IncompleteBatch),
            .invalid => |err| return self.tail(err),
        }
    }

    fn tail(self: *Scanner, err: anyerror) Error!?Batch {
        if (self.mode == .sealed) return @errorCast(err);
        self.has_tail = true;
        self.finished = true;
        return null;
    }
};

pub fn FileScanner(comptime Device: type) type {
    return struct {
        device: Device,
        header: segment.Header,
        mode: Mode,
        length: u64,
        offset: u64,
        order: Order,
        finished: bool = false,
        has_tail: bool = false,
        window: []u8 = &.{},
        window_start: u64 = 0,
        window_len: usize = 0,

        const Self = @This();

        pub fn init(device: Device, expected: segment.Header, mode: Mode, order: Order, max_size: u64) !Self {
            const length = try device.length();
            if (length > max_size) return error.SegmentTooLarge;
            if (length < segment.encoded_len) return error.TruncatedHeader;
            var bytes: [segment.encoded_len]u8 = undefined;
            try device.readExact(&bytes, 0);
            const header = try segment.Header.decode(&bytes);
            try header.checkIdentity(expected);
            return .{ .device = device, .header = header, .mode = mode, .length = length, .offset = segment.encoded_len, .order = order };
        }

        pub fn seek(self: *Self, offset: u64) !void {
            if (offset < segment.encoded_len or offset > self.length) return error.InvalidOffset;
            self.offset = offset;
        }

        /// Batches borrow `scratch` until the next call.
        pub fn next(self: *Self, scratch: []u8) !?Batch {
            if (self.finished) return null;
            if (scratch.len < frame.header_len) return error.BufferTooSmall;
            while (true) {
                const reusable = scratch.ptr == self.window.ptr and scratch.len == self.window.len and
                    self.offset >= self.window_start and self.offset <= self.window_start + self.window_len;
                if (!reusable) try self.refill(scratch);
                const start: usize = @intCast(self.offset - self.window_start);
                const bytes = scratch[start..self.window_len];
                switch (step(bytes, self.offset, self.header.salt, &self.order)) {
                    .batch => |batch| {
                        self.offset += batch.bytes.len;
                        return batch;
                    },
                    .end => if (self.offset == self.length) {
                        self.finished = true;
                        return null;
                    } else try self.refill(scratch),
                    .truncated => {
                        if (self.window_start + self.window_len == self.length) return self.tail(error.IncompleteBatch);
                        if (start == 0) return error.BufferTooSmall;
                        try self.refill(scratch);
                    },
                    .invalid => |err| return self.tail(err),
                }
            }
        }

        fn refill(self: *Self, scratch: []u8) !void {
            const len: usize = @intCast(@min(scratch.len, self.length - self.offset));
            try self.device.readExact(scratch[0..len], self.offset);
            self.window = scratch;
            self.window_start = self.offset;
            self.window_len = len;
        }

        fn tail(self: *Self, err: anyerror) !?Batch {
            if (self.mode == .sealed) return err;
            self.has_tail = true;
            self.finished = true;
            return null;
        }
    };
}
