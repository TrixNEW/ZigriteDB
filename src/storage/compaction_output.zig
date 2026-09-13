const std = @import("std");

const File = @import("../io/file.zig").File;
const files = @import("files.zig");
const segment = @import("../format/segment.zig");
const Region = @import("../format/key.zig").Region;

pub const CompactionOutput = struct {
    io: std.Io,
    dir: std.Io.Dir,
    generation: u64,
    region: Region,
    max_size: u64,
    ids: []u64,
    count: usize = 0,
    file: ?File = null,
    offset: u64 = 0,
    bytes: u64 = 0,

    pub fn deinit(self: *CompactionOutput) void {
        if (self.file) |file| file.handle.close(self.io);
        self.file = null;
    }

    pub fn append(self: *CompactionOutput, batch: []const u8) !void {
        if (batch.len == 0) return;
        if (batch.len > self.max_size - segment.encoded_len) return error.BatchTooLarge;
        if (self.file == null or batch.len > self.max_size - self.offset) try self.rotate();
        try self.file.?.writeAll(batch, self.offset);
        self.offset += batch.len;
        self.bytes = try std.math.add(u64, self.bytes, batch.len);
    }

    pub fn finish(self: *CompactionOutput) !void {
        if (self.file == null) try self.rotate();
        try self.file.?.sync();
    }

    fn rotate(self: *CompactionOutput) !void {
        if (self.count == self.ids.len) return error.TooManySegments;
        if (self.file) |file| {
            try file.sync();
            file.handle.close(self.io);
            self.file = null;
        }
        const id = self.count + 1;
        const handle = try files.createSegment(self.dir, self.io, self.generation, id);
        self.file = .{ .handle = handle, .io = self.io };
        const header = try (segment.Header{
            .generation = self.generation,
            .segment_id = id,
            .region = self.region,
        }).encode();
        try self.file.?.writeAll(&header, 0);
        self.ids[self.count] = id;
        self.count += 1;
        self.offset = segment.encoded_len;
        self.bytes = try std.math.add(u64, self.bytes, segment.encoded_len);
    }
};
