const std = @import("std");

const Region = @import("../format/key.zig").Region;
const segment = @import("../format/segment.zig");
const File = @import("../io/file.zig").File;
const files = @import("files.zig");

pub const CompactionOutput = struct {
    io: std.Io,
    dir: std.Io.Dir,
    generation: u64,
    region: Region,
    salt: u64,
    max_size: u64,
    ids: []u64,
    devices: []File,
    count: usize = 0,
    offset: u64 = 0,
    bytes: u64 = 0,
    synced: usize = 0,

    pub fn deinit(self: *CompactionOutput) void {
        for (self.devices[0..self.count]) |device| device.handle.close(self.io);
        self.count = 0;
    }

    pub fn discard(self: *CompactionOutput) void {
        const count = self.count;
        self.deinit();
        for (self.ids[0..count]) |id| files.removeSegment(self.dir, self.io, self.generation, id) catch {};
    }

    pub const Placed = struct {
        position: usize,
        offset: u64,
    };

    pub fn append(self: *CompactionOutput, bytes: []const u8) !Placed {
        if (bytes.len > self.max_size - segment.encoded_len) return error.BatchTooLarge;
        if (self.count == 0 or bytes.len > self.max_size - self.offset) try self.rotate();
        const offset = self.offset;
        try self.devices[self.count - 1].writeAll(bytes, offset);
        self.offset += bytes.len;
        self.bytes += bytes.len;
        return .{ .position = self.count - 1, .offset = offset };
    }

    /// Creates a segment if none exist yet.
    pub fn sync(self: *CompactionOutput) !void {
        if (self.count == 0) try self.rotate();
        for (self.devices[self.synced..self.count]) |device| try device.sync();
        self.synced = self.count - 1;
    }

    fn rotate(self: *CompactionOutput) !void {
        if (self.count == self.ids.len) return error.TooManySegments;
        const id = self.count + 1;
        const handle = try files.createSegment(self.dir, self.io, self.generation, id);
        const device: File = .{ .handle = handle, .io = self.io };
        self.devices[self.count] = device;
        self.ids[self.count] = id;
        self.count += 1;
        const header = try (segment.Header{ .generation = self.generation, .segment_id = id, .region = self.region, .salt = self.salt }).encode();
        try device.writeAll(&header, 0);
        self.offset = segment.encoded_len;
        self.bytes += segment.encoded_len;
    }
};
