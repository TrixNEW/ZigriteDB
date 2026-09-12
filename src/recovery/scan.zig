const std = @import("std");
const entry = @import("../format/entry.zig");
const record = @import("../format/record.zig");
const segment = @import("../format/segment.zig");
const commit = @import("../batch/commit.zig");

pub const Error = commit.Error || segment.Error || error{
    IncompleteBatch,
    BatchOrder,
};

/// Active segments may end with an incomplete batch; sealed segments may not.
pub const Mode = enum { sealed, active };

pub const Batch = struct {
    id: u64,
    records: []const u8,
    end_offset: usize,
};

/// Keep bytes unchanged while reading batches or using returned records.
pub const Scanner = struct {
    bytes: []const u8,
    header: segment.Header,
    mode: Mode,
    offset: usize = segment.encoded_len,
    last_batch_id: u64,
    finished: bool = false,
    has_tail: bool = false,

    /// Pass the previous segment's last batch ID, or zero for the first segment.
    pub fn init(bytes: []const u8, expected: segment.Header, mode: Mode, last_batch_id: u64) Error!Scanner {
        const header = try segment.Header.decode(bytes);
        try header.checkIdentity(expected);
        return .{ .bytes = bytes, .header = header, .mode = mode, .last_batch_id = last_batch_id };
    }

    /// Returns a whole verified batch. Errors leave the scan position unchanged.
    pub fn next(self: *Scanner) Error!?Batch {
        if (self.finished) return null;
        if (self.offset == self.bytes.len) {
            self.finished = true;
            return null;
        }

        var position = self.offset;
        var count: usize = 0;
        var batch_id: u64 = 0;
        while (position < self.bytes.len) {
            const remaining = self.bytes[position..];
            const header = record.Header.decode(remaining) catch |err| switch (err) {
                error.TruncatedHeader => return self.tail(),
                else => return err,
            };
            if (header.kind == .commit) {
                if (count == 0) return error.InvalidCommit;
                if (remaining.len < commit.commit_len) return self.tail();
                const records = self.bytes[self.offset..position];
                try commit.verify(records, remaining[0..commit.commit_len]);
                const end = std.math.add(usize, position, commit.commit_len) catch return error.InvalidLength;
                self.offset = end;
                self.last_batch_id = batch_id;
                return .{ .id = batch_id, .records = records, .end_offset = end };
            }

            if (count == commit.max_records) return error.BatchTooLarge;
            if (header.batch_id <= self.last_batch_id) return error.BatchOrder;
            if (count != 0 and header.batch_id != batch_id) return error.BatchIdMismatch;
            const decoded = entry.decode(remaining) catch |err| switch (err) {
                error.TruncatedRecord => return self.tail(),
                else => return err,
            };
            const region = decoded.entry.key.region();
            if (region.dimension != self.header.region.dimension or
                region.x != self.header.region.x or region.z != self.header.region.z)
                return error.RegionMismatch;
            batch_id = header.batch_id;
            position = std.math.add(usize, position, decoded.consumed) catch return error.BatchTooLarge;
            if (position - self.offset > commit.max_bytes) return error.BatchTooLarge;
            count += 1;
        }
        return self.tail();
    }

    fn tail(self: *Scanner) Error!?Batch {
        if (self.mode == .sealed) return error.IncompleteBatch;
        self.has_tail = true;
        self.finished = true;
        return null;
    }
};
