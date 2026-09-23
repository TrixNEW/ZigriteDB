const std = @import("std");

const WriteBatch = @import("../batch/write.zig").WriteBatch;
const Entry = @import("../format/entry.zig").Entry;
const Key = @import("../format/key.zig").Key;
const KeyFilter = @import("../format/key.zig").KeyFilter;
const Region = @import("../format/key.zig").Region;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const File = @import("../io/file.zig").File;
const compactBatch = @import("../storage/compact_batch.zig").compactBatch;
const CompactionOutput = @import("../storage/compaction_output.zig").CompactionOutput;
const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");
const publication = @import("../storage/publication.zig");
const reclamation = @import("../storage/reclamation.zig");
const writer = @import("../storage/writer.zig");
const shard_module = @import("shard.zig");
pub const Options = shard_module.Options;

const Scanner = @import("../recovery/file_scan.zig").Scanner(File);
const Shard = shard_module.Shard(File);

pub const ReadRequest = Shard.ReadRequest;
pub const ReadStatus = Shard.ReadStatus;
pub const ReadResult = Shard.ReadResult;
pub const max_batch_keys = Shard.max_batch_keys;

pub const CompactionResult = struct {
    generation: u64,
    segment_count: usize,
    source_bytes: u64,
    output_bytes: u64,
    cleanup: reclamation.Result,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: Directory,
    shard: Shard,
    devices: []File,
    file_count: usize,
    region: Region,
    mutex: std.Io.Mutex = .init,
    writer_mutex: std.Io.Mutex = .init,
    closed: bool = false,
    // Group commit shares one fsync among waiting writers.
    commit_mutex: std.Io.Mutex = .init,
    committed: std.Io.Condition = .init,
    appended_ticket: u64 = 0,
    synced_ticket: u64 = 0,
    syncing: bool = false,
    commit_error: ?anyerror = null,

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
        errdefer |err| {
            if (err == error.OutOfMemory and (devices[0].length() catch 1) == 0) {
                files.removeSegment(directory.dir, io, 1, 1) catch {};
                directory.syncEntries() catch {};
            }
        }

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
            .region = region,
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
            .region = metadata.region,
        };
    }

    /// Sync writes share one fsync among concurrent callers.
    pub fn write(self: *Store, batch: WriteBatch) !writer.AppendResult {
        return self.commitWrite(batch, null);
    }

    /// Writes with the next batch ID for this region.
    pub fn writeNext(self: *Store, entries: []Entry) !writer.AppendResult {
        return self.commitWrite(.{ .entries = entries }, entries);
    }

    fn commitWrite(self: *Store, batch: WriteBatch, assign: ?[]Entry) !writer.AppendResult {
        var result, const ticket = blk: {
            try self.writer_mutex.lock(self.io);
            defer self.writer_mutex.unlock(self.io);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (assign) |entries| {
                const id = std.math.add(u64, self.shard.writer.last_batch_id, 1) catch return error.BatchOrder;
                for (entries) |*item| item.header.batch_id = id;
            }
            if (self.shard.options.durability == .buffered) return self.writeLocked(batch);
            self.shard.options.durability = .buffered;
            defer self.shard.options.durability = .sync;
            const result = try self.writeLocked(batch);
            break :blk .{ result, self.nextTicket() };
        };
        try self.waitDurable(ticket);
        result.synced = true;
        return result;
    }

    pub fn writeGroup(self: *Store, batches: []const WriteBatch) !void {
        try @import("../batch/group.zig").validate(batches);
        const ticket = blk: {
            try self.writer_mutex.lock(self.io);
            defer self.writer_mutex.unlock(self.io);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            for (batches) |batch| {
                const size = try batch.size();
                if (size > self.shard.options.batch_buffer_size) return error.BufferTooSmall;
                if (size > self.shard.options.max_segment_size - segment.encoded_len) return error.BatchTooLarge;
            }
            const durability = self.shard.options.durability;
            self.shard.options.durability = .buffered;
            defer self.shard.options.durability = durability;
            for (batches) |batch| _ = try self.writeLocked(batch);
            break :blk self.nextTicket();
        };
        try self.waitDurable(ticket);
    }

    fn nextTicket(self: *Store) u64 {
        self.commit_mutex.lockUncancelable(self.io);
        defer self.commit_mutex.unlock(self.io);
        self.appended_ticket += 1;
        return self.appended_ticket;
    }

    fn waitDurable(self: *Store, ticket: u64) !void {
        self.commit_mutex.lockUncancelable(self.io);
        defer self.commit_mutex.unlock(self.io);

        while (self.synced_ticket < ticket) {
            if (self.commit_error) |err| return err;
            if (self.syncing) {
                self.committed.waitUncancelable(self.io, &self.commit_mutex);
                continue;
            }

            self.syncing = true;
            const target = self.appended_ticket;
            self.commit_mutex.unlock(self.io);
            const result = self.shard.syncAppended();
            self.commit_mutex.lockUncancelable(self.io);
            self.syncing = false;
            if (result) |_| self.synced_ticket = target else |err| self.commit_error = err;
            self.committed.broadcast(self.io);
        }
    }

    /// Syncs all appends before devices are swapped or closed.
    fn commitBarrier(self: *Store) !void {
        self.commit_mutex.lockUncancelable(self.io);
        defer self.commit_mutex.unlock(self.io);
        defer self.committed.broadcast(self.io);

        while (self.syncing) self.committed.waitUncancelable(self.io, &self.commit_mutex);
        if (self.commit_error) |err| return err;
        self.shard.syncAppended() catch |err| {
            self.commit_error = err;
            return err;
        };
        self.synced_ticket = self.appended_ticket;
    }

    fn writeLocked(self: *Store, batch: WriteBatch) !writer.AppendResult {
        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;

        const size = try batch.size();
        const minimum_size = std.math.add(u64, segment.encoded_len, size) catch return error.BatchTooLarge;
        if (minimum_size > self.shard.options.max_segment_size) return error.BatchTooLarge;
        if (batch.entries[0].header.batch_id <= self.shard.writer.last_batch_id) return error.BatchOrder;
        if (!std.meta.eql(batch.entries[0].key.region(), self.shard.generation.index.region)) return error.RegionMismatch;

        var kept: []Entry = &.{};
        defer if (kept.len != 0) self.allocator.free(kept);
        const batch_to_write = if (self.shard.options.skip_unchanged) blk: {
            const buffer = try self.allocator.alloc(Entry, batch.entries.len);
            var count: usize = 0;
            for (batch.entries, 0..) |item, i| {
                if (!repeated(batch.entries, i) and try self.shard.unchanged(item)) continue;
                buffer[count] = item;
                count += 1;
            }
            if (self.shard.options.stats) |s| _ = s.unchanged_write_skips.fetchAdd(batch.entries.len - count, .monotonic);
            if (count == batch.entries.len) {
                self.allocator.free(buffer);
                break :blk batch;
            }
            kept = buffer;
            if (count == 0) {
                const offset = self.shard.writer.offset;
                return .{ .batch_id = batch.entries[0].header.batch_id, .start = offset, .end = offset, .synced = false };
            }
            break :blk WriteBatch{ .entries = buffer[0..count] };
        } else batch;

        const result = self.shard.write(batch_to_write) catch |err| blk: {
            if (err != error.SegmentFull) return err;

            try self.rotate();
            break :blk try self.shard.write(batch_to_write);
        };

        if (self.shard.options.stats) |s| {
            _ = s.writes.fetchAdd(1, .monotonic);
            _ = s.records_written.fetchAdd(@intCast(batch_to_write.entries.len), .monotonic);
            var raw_bytes: u64 = 0;
            var compressed_bytes: u64 = 0;
            for (batch_to_write.entries) |item| {
                raw_bytes += item.header.raw_len;
                compressed_bytes += item.header.stored_len;
            }
            _ = s.raw_bytes_written.fetchAdd(raw_bytes, .monotonic);
            _ = s.compressed_bytes_written.fetchAdd(compressed_bytes, .monotonic);
        }

        return result;
    }

    fn repeated(entries: []const Entry, index: usize) bool {
        for (entries, 0..) |other, i| {
            if (i != index and std.meta.eql(other.key, entries[index].key)) return true;
        }
        return false;
    }

    pub fn compact(self: *Store) !CompactionResult {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.mutex.lock(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;
        const generation = std.math.add(u64, self.shard.generation.index.generation, 1) catch return error.GenerationExhausted;
        const options = self.shard.options;
        const compaction_started: ?std.Io.Clock.Timestamp = if (options.stats != null) std.Io.Clock.Timestamp.now(self.io, .awake) else null;
        try self.commitBarrier();

        const scratch = try self.allocator.alloc(u8, options.batch_buffer_size + segment.encoded_len);
        defer self.allocator.free(scratch);
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
            .region = self.shard.generation.index.region,
            .max_size = options.max_segment_size,
            .ids = ids,
        };
        defer output.deinit();
        self.mutex.unlock(self.io);
        locked = false;
        var previous: u64 = 0;
        var source_bytes: u64 = 0;
        for (self.devices[0..self.file_count], self.shard.generation.segment_ids[0..self.file_count], 0..) |device, id, position| {
            var scanner = Scanner.init(device, .{
                .generation = self.shard.generation.index.generation,
                .segment_id = id,
                .region = self.shard.generation.index.region,
            }, if (position == self.file_count - 1) .active else .sealed, previous, options.max_segment_size) catch |err| return self.sourceFailure(err);
            source_bytes = try std.math.add(u64, source_bytes, scanner.length);
            while (scanner.next(scratch) catch |err| return self.sourceFailure(err)) |batch| {
                try output.append(try compactBatch(&self.shard.generation.index, position, batch, filtered));
            }
            if (scanner.has_tail) return self.sourceFailure(error.NeedsRecovery);
            previous = scanner.last_batch_id;
        }
        if (previous != self.shard.generation.index.last_batch_id) return self.sourceFailure(error.FileChanged);
        try output.finish();
        const metadata: manifest.Manifest = .{
            .generation = generation,
            .region = self.shard.generation.index.region,
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
        try self.mutex.lock(self.io);
        locked = true;
        var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
        publisher.publish(bytes) catch |err| {
            self.shard.writer.failed = true;
            return err;
        };

        const old_devices = self.devices;
        const old_count = self.file_count;
        const old_generation = self.shard.swap(next.generation, next.writer);
        self.allocator.free(next.scratch);
        self.devices = devices;
        self.file_count = opened;
        self.mutex.unlock(self.io);
        locked = false;

        self.shard.drain(old_generation);
        for (old_devices[0..old_count]) |device| device.handle.close(self.io);
        self.allocator.free(old_devices);

        if (options.stats) |s| {
            _ = s.compactions.fetchAdd(1, .monotonic);
            _ = s.compaction_input_bytes.fetchAdd(source_bytes, .monotonic);
            _ = s.compaction_output_bytes.fetchAdd(output.bytes, .monotonic);
            if (compaction_started) |t| _ = s.compaction_duration_ns.fetchAdd(@intCast(t.untilNow(self.io).raw.nanoseconds), .monotonic);
        }

        const cleanup = reclamation.reclaim(&self.directory, generation, old_generation.index.generation, old_generation.segment_ids[0..old_count]);
        old_generation.destroy();

        return .{
            .generation = generation,
            .segment_count = opened,
            .source_bytes = source_bytes,
            .output_bytes = output.bytes,
            .cleanup = cleanup,
        };
    }

    pub fn reclaim(self: *Store, generation: u64, ids: []const u64) !reclamation.Result {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;
        return reclamation.reclaim(&self.directory, self.shard.generation.index.generation, generation, ids);
    }

    pub fn keys(self: *Store, allocator: std.mem.Allocator, filter: KeyFilter) ![]Key {
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
        }
        return self.shard.keys(allocator, filter);
    }

    pub fn get(self: *Store, key: Key, output: []u8) !?[]const u8 {
        if (self.shard.options.stats) |s| _ = s.get_calls.fetchAdd(1, .monotonic);
        return self.shard.get(key, output);
    }

    pub fn getSized(self: *Store, key: Key, output: []u8, required: *usize) !?[]const u8 {
        required.* = 0;
        if (self.shard.options.stats) |s| _ = s.get_calls.fetchAdd(1, .monotonic);
        return self.shard.getSized(key, output, required);
    }

    pub fn getMany(self: *Store, requests: []const ReadRequest, results: []ReadResult) !void {
        std.debug.assert(requests.len == results.len);
        if (self.shard.options.stats) |s| _ = s.get_calls.fetchAdd(requests.len, .monotonic);
        return self.shard.getMany(requests, results);
    }

    pub fn lastBatchId(self: *Store) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        return self.shard.generation.index.last_batch_id;
    }

    pub fn valueSize(self: *Store, key: Key) !?u32 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        const location = (try self.shard.generation.index.get(key)) orelse return null;
        return location.raw_len;
    }

    pub fn flush(self: *Store) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return error.Closed;

        try self.shard.flush();
    }

    pub fn close(self: *Store) !void {
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;

        self.commitBarrier() catch {};
        const result = self.shard.close();
        self.release();
        try result;
    }

    pub fn deinit(self: *Store) void {
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.closed) self.release();
    }

    fn sourceFailure(self: *Store, err: anyerror) anyerror {
        if (err != error.Canceled) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.shard.writer.failed = true;
        }
        return err;
    }

    fn rotate(self: *Store) !void {
        if (self.file_count == self.shard.options.max_segments) return error.TooManySegments;

        const id = std.math.add(u64, self.shard.writer.header.segment_id, 1) catch return error.SegmentIdExhausted;
        const handle = try files.createSegment(self.directory.dir, self.io, self.shard.generation.index.generation, id);
        errdefer handle.close(self.io);

        const device: File = .{ .handle = handle, .io = self.io };
        var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
        try self.shard.rotate(device, id, &publisher);

        self.devices[self.file_count] = device;
        self.file_count += 1;
        if (self.shard.options.stats) |s| _ = s.segment_rotations.fetchAdd(1, .monotonic);
    }

    fn release(self: *Store) void {
        self.shard.deinit();

        for (self.devices[0..self.file_count]) |device| device.handle.close(self.io);
        self.allocator.free(self.devices);
        self.directory.deinit();
        self.closed = true;
    }
};
