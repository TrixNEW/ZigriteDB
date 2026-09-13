const std = @import("std");

const WriteBatch = @import("../batch/write.zig").WriteBatch;
const Key = @import("../format/key.zig").Key;
const Region = @import("../format/key.zig").Region;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const File = @import("../io/file.zig").File;
const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");
const publication = @import("../storage/publication.zig");
const writer = @import("../storage/writer.zig");
const shard_module = @import("shard.zig");

pub const Options = shard_module.Options;
const Shard = shard_module.Shard(File);

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: Directory,
    shard: Shard,
    devices: []File,
    file_count: usize,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, region: Region, options: Options) !Store {
        try options.validate();

        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();

        var iterator = directory.dir.iterate();
        if (try iterator.next(io) != null) return error.DirectoryNotEmpty;

        const devices = try allocator.alloc(File, options.max_segments);
        errdefer allocator.free(devices);

        const handle = try files.createSegment(directory.dir, io, 1, 1);
        errdefer handle.close(io);
        devices[0] = .{ .handle = handle, .io = io };

        var shard = try Shard.create(allocator, io, devices[0], .{
            .generation = 1,
            .segment_id = 1,
            .region = region,
        }, options);
        errdefer shard.deinit();

        var buffer: [manifest.header_len + 12]u8 = undefined;
        const bytes = try (manifest.Manifest{
            .generation = 1,
            .region = region,
            .segments = &.{1},
        }).encode(&buffer);
        var publisher: publication.Publisher(*Directory) = .{ .backend = &directory };
        try publisher.publish(bytes);

        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .shard = shard,
            .devices = devices,
            .file_count = 1,
        };
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !Store {
        try options.validate();

        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();

        if (directory.dir.statFile(io, "MANIFEST.tmp", .{ .follow_symlinks = false })) |_| {
            return error.NeedsRecovery;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const handle = try files.openManifest(directory.dir, io);
        defer handle.close(io);
        const file: File = .{ .handle = handle, .io = io };
        const length = try file.length();

        if (length > manifest.max_encoded_len) return error.ManifestTooLarge;

        const bytes = try allocator.alloc(u8, @intCast(length));
        defer allocator.free(bytes);
        const ids = try allocator.alloc(u64, options.max_segments);
        defer allocator.free(ids);

        try file.readExact(bytes, 0);
        const metadata = try manifest.decode(bytes, ids);
        const devices = try allocator.alloc(File, options.max_segments);
        errdefer allocator.free(devices);
        var count: usize = 0;
        errdefer for (devices[0..count]) |device| device.handle.close(io);

        for (metadata.segments, 0..) |id, position| {
            const segment_file = try files.openSegment(
                directory.dir,
                io,
                metadata.generation,
                id,
                position == metadata.segments.len - 1,
            );
            devices[count] = .{ .handle = segment_file, .io = io };
            count += 1;
        }

        const shard = try Shard.openSegments(allocator, io, devices[0..count], metadata, options);

        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .shard = shard,
            .devices = devices,
            .file_count = count,
        };
    }

    pub fn write(self: *Store, batch: WriteBatch) !writer.AppendResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;

        const size = try batch.size();
        const minimum_size = std.math.add(u64, segment.encoded_len, size) catch return error.BatchTooLarge;
        if (minimum_size > self.shard.options.max_segment_size) return error.BatchTooLarge;
        if (batch.entries[0].header.batch_id <= self.shard.writer.last_batch_id) return error.BatchOrder;
        if (!std.meta.eql(batch.entries[0].key.region(), self.shard.index.region)) return error.RegionMismatch;

        return self.shard.write(batch) catch |err| {
            if (err != error.SegmentFull) return err;

            try self.rotate();
            return self.shard.write(batch);
        };
    }

    pub fn get(self: *Store, key: Key, output: []u8) !?[]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.Closed;

        return self.shard.get(key, output);
    }

    pub fn flush(self: *Store) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.Closed;

        try self.shard.flush();
    }

    pub fn close(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;

        const result = self.shard.close();
        self.release();
        try result;
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.closed) self.release();
    }

    fn rotate(self: *Store) !void {
        if (self.file_count == self.shard.options.max_segments) return error.TooManySegments;

        const id = std.math.add(u64, self.shard.writer.header.segment_id, 1) catch return error.SegmentIdExhausted;
        const handle = try files.createSegment(self.directory.dir, self.io, self.shard.index.generation, id);
        errdefer handle.close(self.io);

        const device: File = .{ .handle = handle, .io = self.io };
        var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
        try self.shard.rotate(device, id, &publisher);

        self.devices[self.file_count] = device;
        self.file_count += 1;
    }

    fn release(self: *Store) void {
        self.shard.deinit();

        for (self.devices[0..self.file_count]) |device| device.handle.close(self.io);
        self.allocator.free(self.devices);
        self.directory.deinit();
        self.closed = true;
    }
};
