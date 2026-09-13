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
const Scanner = @import("../recovery/file_scan.zig").Scanner(File);
const CompactionOutput = @import("../storage/compaction_output.zig").CompactionOutput;
const compactBatch = @import("../storage/compact_batch.zig").compactBatch;
const shard_module = @import("shard.zig");

pub const Options = shard_module.Options;
const Shard = shard_module.Shard(File);

pub const CompactionResult = struct {
    generation: u64,
    segment_count: usize,
    source_bytes: u64,
    output_bytes: u64,
};

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

    /// Installs a compacted generation and leaves the old files intact.
    pub fn compact(self: *Store) !CompactionResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;
        const generation = std.math.add(u64, self.shard.index.generation, 1) catch return error.GenerationExhausted;
        const options = self.shard.options;
        try self.shard.flush();

        const ids = try self.allocator.alloc(u64, options.max_segments);
        defer self.allocator.free(ids);
        const filtered = try self.allocator.alloc(u8, options.batch_buffer_size);
        defer self.allocator.free(filtered);
        const manifest_buffer = try self.allocator.alloc(u8, manifest.header_len + options.max_segments * 8 + 4);
        defer self.allocator.free(manifest_buffer);
        const devices = try self.allocator.alloc(File, options.max_segments);
        errdefer self.allocator.free(devices);
        var opened: usize = 0;
        errdefer for (devices[0..opened]) |device| device.handle.close(self.io);

        var output: CompactionOutput = .{
            .io = self.io,
            .dir = self.directory.dir,
            .generation = generation,
            .region = self.shard.index.region,
            .max_size = options.max_segment_size,
            .ids = ids,
        };
        defer output.deinit();
        var previous: u64 = 0;
        var source_bytes: u64 = 0;
        for (self.devices[0..self.file_count], self.shard.segment_ids[0..self.file_count], 0..) |device, id, position| {
            var scanner = try Scanner.init(device, .{
                .generation = self.shard.index.generation,
                .segment_id = id,
                .region = self.shard.index.region,
            }, if (position == self.file_count - 1) .active else .sealed, previous, options.max_segment_size);
            source_bytes = try std.math.add(u64, source_bytes, scanner.length);
            while (try scanner.next(self.shard.scratch)) |batch| {
                try output.append(try compactBatch(&self.shard.index, id, batch, filtered));
            }
            if (scanner.has_tail) return error.NeedsRecovery;
            previous = scanner.last_batch_id;
        }
        if (previous != self.shard.index.last_batch_id) return error.FileChanged;
        try output.finish();
        const metadata: manifest.Manifest = .{
            .generation = generation,
            .region = self.shard.index.region,
            .segments = ids[0..output.count],
        };
        const bytes = try metadata.encode(manifest_buffer);
        for (metadata.segments, 0..) |id, position| {
            devices[opened] = .{
                .handle = try files.openSegment(self.directory.dir, self.io, generation, id, position == output.count - 1),
                .io = self.io,
            };
            opened += 1;
        }
        var next = try Shard.openSegments(self.allocator, self.io, devices[0..opened], metadata, options);
        errdefer next.deinit();
        var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
        publisher.publish(bytes) catch |err| {
            self.shard.writer.failed = true;
            return err;
        };

        var old = self.shard;
        defer old.deinit();
        const old_devices = self.devices;
        const old_count = self.file_count;
        self.shard = next;
        self.devices = devices;
        self.file_count = opened;
        for (old_devices[0..old_count]) |device| device.handle.close(self.io);
        self.allocator.free(old_devices);

        return .{
            .generation = generation,
            .segment_count = opened,
            .source_bytes = source_bytes,
            .output_bytes = output.bytes,
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
