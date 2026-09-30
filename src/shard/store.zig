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
const commit = @import("../batch/commit.zig");
const Index = @import("../index/index.zig").Index;
const entry = @import("../format/entry.zig");
const Batch = @import("../recovery/scan.zig").Batch;
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
    commit_mutex: std.Io.Mutex = .init,
    committed: std.Io.Condition = .init,
    appended_ticket: u64 = 0,
    synced_ticket: u64 = 0,
    syncing: bool = false,
    commit_error: ?anyerror = null,
    compact_mutex: std.Io.Mutex = .init,
    // Guards manifest publication and segment removal.
    directory_mutex: std.Io.Mutex = .init,
    compaction_hint: std.atomic.Value(bool) = .init(false),

    pub fn create(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, region: Region, options: Options) !Store {
        try options.validate();

        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();

        try discardUnpublished(&directory);
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

    fn discardUnpublished(directory: *Directory) !void {
        const io = directory.io;
        const first = "0000000000000001-0000000000000001.segment";
        var has_segment = false;
        var has_temporary = false;
        var iterator = directory.dir.iterate();
        while (try iterator.next(io)) |item| {
            if (item.kind == .file and std.mem.eql(u8, item.name, first)) {
                has_segment = true;
            } else if (item.kind == .file and std.mem.eql(u8, item.name, "MANIFEST.tmp")) {
                has_temporary = true;
            } else return;
        }
        if (has_segment) {
            const stat = try directory.dir.statFile(io, first, .{ .follow_symlinks = false });
            if (stat.size > segment.encoded_len) return;
            try directory.dir.deleteFile(io, first);
        }
        if (has_temporary) try directory.dir.deleteFile(io, "MANIFEST.tmp");
        if (has_segment or has_temporary) try directory.syncEntries();
    }

    /// Only a compaction that never published creates segments of the next generation.
    fn discardUnfinished(directory: *Directory, current: u64) !void {
        const next = std.math.add(u64, current, 1) catch return;
        var prefix_buffer: [17]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{x:0>16}-", .{next});
        var removed = false;
        var iterator = directory.dir.iterate();
        while (try iterator.next(directory.io)) |item| {
            if (item.kind != .file or !std.mem.startsWith(u8, item.name, prefix) or !std.mem.endsWith(u8, item.name, ".segment")) continue;
            try directory.dir.deleteFile(directory.io, item.name);
            removed = true;
        }
        if (removed) try directory.syncEntries();
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
        try discardUnfinished(&directory, metadata.generation);
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

    pub fn write(self: *Store, batch: WriteBatch) !writer.AppendResult {
        return self.commitWrite(batch, null);
    }

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
            if (self.shard.writer.failed) return error.WriterFailed;
            for (batches) |batch| {
                const size = try batch.validate();
                if (size > self.shard.options.batch_buffer_size) return error.BufferTooSmall;
                if (size > self.shard.options.max_segment_size - segment.encoded_len) return error.BatchTooLarge;
            }
            const durability = self.shard.options.durability;
            self.shard.options.durability = .buffered;
            defer self.shard.options.durability = durability;
            if (self.shard.options.skip_unchanged) {
                for (batches) |batch| _ = try self.writeLocked(batch);
            } else {
                var rest = batches;
                while (rest.len != 0) {
                    const written = self.shard.writeBatches(rest, true) catch |err| retry: {
                        if (err != error.SegmentFull) return err;
                        try self.rotate();
                        break :retry try self.shard.writeBatches(rest, true);
                    };
                    for (rest[0..written.count]) |batch| self.recordWrite(batch);
                    rest = rest[written.count..];
                }
                self.checkStale();
            }
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

        self.recordWrite(batch_to_write);
        self.checkStale();
        return result;
    }

    fn checkStale(self: *Store) void {
        const options = self.shard.options;
        const index = &self.shard.generation.index;
        if (index.total_bytes < options.compact_min_bytes or index.live_bytes == index.total_bytes) return;
        const stale = index.live_bytes * 100 < index.total_bytes * options.compact_live_percent;
        const crowded = self.file_count * 4 >= options.max_segments * 3;
        if (stale or crowded) self.compaction_hint.store(true, .monotonic);
    }

    /// True once each time the store goes stale.
    pub fn wantsCompaction(self: *Store) bool {
        return self.compaction_hint.swap(false, .monotonic);
    }

    fn recordWrite(self: *Store, batch: WriteBatch) void {
        const s = self.shard.options.stats orelse return;
        _ = s.writes.fetchAdd(1, .monotonic);
        _ = s.records_written.fetchAdd(@intCast(batch.entries.len), .monotonic);
        var raw_bytes: u64 = 0;
        var compressed_bytes: u64 = 0;
        for (batch.entries) |item| {
            raw_bytes += item.header.raw_len;
            compressed_bytes += item.header.stored_len;
        }
        _ = s.raw_bytes_written.fetchAdd(raw_bytes, .monotonic);
        _ = s.compressed_bytes_written.fetchAdd(compressed_bytes, .monotonic);
    }

    fn repeated(entries: []const Entry, index: usize) bool {
        for (entries, 0..) |other, i| {
            if (i != index and std.meta.eql(other.key, entries[index].key)) return true;
        }
        return false;
    }

    /// Writers only wait for the final tail copy, fsync and manifest swap.
    pub fn compact(self: *Store) !CompactionResult {
        try self.compact_mutex.lock(self.io);
        defer self.compact_mutex.unlock(self.io);

        const options = self.shard.options;
        const started: ?std.Io.Clock.Timestamp = if (options.stats != null) std.Io.Clock.Timestamp.now(self.io, .awake) else null;
        const snapshot = try self.end();
        const old = self.shard.generation;
        const generation = std.math.add(u64, old.index.generation, 1) catch return error.GenerationExhausted;

        const scratch = try self.allocator.alloc(u8, options.batch_buffer_size + segment.encoded_len);
        defer self.allocator.free(scratch);
        const filtered = try self.allocator.alloc(u8, options.batch_buffer_size);
        defer self.allocator.free(filtered);
        const manifest_buffer = try self.allocator.alloc(u8, manifest.header_len + options.max_segments * 8 + 4);
        defer self.allocator.free(manifest_buffer);
        const ids = try self.allocator.alloc(u64, options.max_segments);
        var ids_owned = true;
        defer if (ids_owned) self.allocator.free(ids);
        const devices = try self.allocator.alloc(File, options.max_segments);
        var devices_owned = true;
        defer if (devices_owned) self.allocator.free(devices);
        const shard_devices = try self.allocator.alloc(File, options.max_segments);
        var shard_devices_owned = true;
        defer if (shard_devices_owned) self.allocator.free(shard_devices);
        var moves: std.ArrayListUnmanaged(Move) = .empty;
        defer moves.deinit(self.allocator);

        var output: CompactionOutput = .{
            .io = self.io,
            .dir = self.directory.dir,
            .generation = generation,
            .region = old.index.region,
            .max_size = options.max_segment_size,
            .ids = ids,
        };
        defer output.deinit();
        var tail: Tail = .{ .start = snapshot.position, .position = snapshot.position, .offset = snapshot.offset, .base = snapshot.offset - segment.encoded_len };
        defer for (devices[tail.first..tail.opened]) |device| device.handle.close(self.io);
        var published = false;
        errdefer if (!published) for (ids[0..@max(output.count, tail.opened)]) |id| files.removeSegment(self.directory.dir, self.io, generation, id) catch {};

        var job: Job = .{ .moves = &moves, .filtered = filtered, .keep_id = snapshot.last_batch_id };
        var previous: u64 = 0;
        for (0..snapshot.position + 1) |position| {
            const active = position == snapshot.position;
            var scanner = Scanner.init(self.devices[position], .{
                .generation = old.index.generation,
                .segment_id = old.segment_ids[position],
                .region = old.index.region,
            }, if (active) .active else .sealed, previous, options.max_segment_size) catch |err| return self.sourceFailure(err);
            if (active) scanner.length = @min(scanner.length, snapshot.offset);
            job.source_bytes += scanner.length;
            while (scanner.next(scratch) catch |err| return self.sourceFailure(err)) |batch| {
                try self.keepLive(&job, &output, old, position, batch);
            }
            if (scanner.has_tail) return self.sourceFailure(error.NeedsRecovery);
            previous = scanner.last_batch_id;
        }
        if (previous != snapshot.last_batch_id) return self.sourceFailure(error.FileChanged);
        if (output.file) |file| try file.sync();
        tail.first = output.count;
        tail.opened = output.count;
        tail.synced = output.count;

        for (0..4) |_| {
            const copied = try self.copyTail(&tail, try self.end(), generation, ids, devices, scratch);
            job.tail_bytes += copied;
            if (copied <= catch_up_bytes) break;
        }

        const retired, const old_devices, const old_count, const count = blk: {
            try self.writer_mutex.lock(self.io);
            defer self.writer_mutex.unlock(self.io);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            if (self.shard.writer.failed) return error.WriterFailed;

            const current = self.shard.writer;
            const active = self.file_count - 1;
            job.tail_bytes += try self.copyTail(&tail, .{ .position = active, .offset = current.offset, .last_batch_id = current.last_batch_id }, generation, ids, devices, scratch);
            const has_tail = active != tail.start or current.offset != snapshot.offset;
            if (has_tail) {
                while (tail.opened <= tail.first + active - tail.start) try self.openTailSegment(&tail, generation, ids, devices);
                for (devices[tail.synced..tail.opened]) |device| try device.sync();
            } else try output.finish();

            const count = if (has_tail) tail.opened else output.count;
            var opened: usize = 0;
            errdefer for (devices[0..opened]) |device| device.handle.close(self.io);
            for (ids[0..output.count], 0..) |id, position| {
                devices[position] = .{
                    .handle = try files.openSegment(self.directory.dir, self.io, generation, id, !has_tail and position == count - 1),
                    .io = self.io,
                };
                opened += 1;
            }

            var next = try self.remap(&old.index, moves.items, snapshot, tail, generation, ids);
            errdefer next.deinit();
            next.total_bytes = job.kept_bytes + (old.index.total_bytes - snapshot.total_bytes);
            const fresh = try self.allocator.create(Shard.Generation);
            errdefer self.allocator.destroy(fresh);
            const bytes = try (manifest.Manifest{
                .generation = generation,
                .region = old.index.region,
                .segments = ids[0..count],
            }).encode(manifest_buffer);

            published = true;
            {
                self.directory_mutex.lockUncancelable(self.io);
                defer self.directory_mutex.unlock(self.io);
                var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
                publisher.publish(bytes) catch |err| {
                    self.shard.writer.failed = true;
                    return err;
                };
            }

            const offset = if (!has_tail) output.offset else if (active == tail.start) current.offset - tail.base else current.offset;
            next.active_offset = @intCast(offset);
            @memcpy(shard_devices[0..count], devices[0..count]);
            fresh.* = .{
                .allocator = self.allocator,
                .index = next,
                .devices = shard_devices,
                .segment_ids = ids,
                .segment_count = count,
            };
            ids_owned = false;
            shard_devices_owned = false;
            tail.opened = tail.first;
            opened = 0;

            const retired = self.shard.swap(fresh, .{
                .device = devices[count - 1],
                .header = .{ .segment_id = ids[count - 1], .generation = generation, .region = old.index.region },
                .max_size = options.max_segment_size,
                .offset = offset,
                .synced_offset = offset,
                .last_batch_id = current.last_batch_id,
                .stats = options.stats,
                .io = self.io,
            });
            const old_devices = self.devices;
            const old_count = self.file_count;
            self.devices = devices;
            self.file_count = count;
            devices_owned = false;
            break :blk .{ retired, old_devices, old_count, count };
        };

        self.shard.drain(retired);
        for (old_devices[0..old_count]) |device| device.handle.close(self.io);
        self.allocator.free(old_devices);

        const output_bytes = output.bytes + job.tail_bytes;
        if (options.stats) |s| {
            _ = s.compactions.fetchAdd(1, .monotonic);
            // One per new segment plus the manifest file and two directory syncs.
            _ = s.fsync_count.fetchAdd(count + 3, .monotonic);
            _ = s.compaction_input_bytes.fetchAdd(job.source_bytes + job.tail_bytes, .monotonic);
            _ = s.compaction_output_bytes.fetchAdd(output_bytes, .monotonic);
            if (started) |t| _ = s.compaction_duration_ns.fetchAdd(@intCast(t.untilNow(self.io).raw.nanoseconds), .monotonic);
        }

        const cleanup = blk: {
            self.directory_mutex.lockUncancelable(self.io);
            defer self.directory_mutex.unlock(self.io);
            break :blk reclamation.reclaim(&self.directory, generation, retired.index.generation, retired.segment_ids[0..old_count]);
        };
        retired.destroy();

        return .{
            .generation = generation,
            .segment_count = count,
            .source_bytes = job.source_bytes + job.tail_bytes,
            .output_bytes = output_bytes,
            .cleanup = cleanup,
        };
    }

    const catch_up_bytes = 256 * 1024;

    const End = struct {
        position: usize,
        offset: u64,
        last_batch_id: u64,
        total_bytes: u64 = 0,
    };

    const Move = struct {
        segment: u16,
        offset: u64,
        to_segment: u16,
        to_offset: u64,
    };

    /// Writes after the snapshot, copied as-is. The first piece starts a fresh segment;
    /// later old segments map one to one.
    const Tail = struct {
        start: usize,
        position: usize,
        offset: u64,
        base: u64,
        first: usize = 0,
        opened: usize = 0,
        synced: usize = 0,
    };

    const Job = struct {
        moves: *std.ArrayListUnmanaged(Move),
        filtered: []u8,
        keep_id: u64,
        source_bytes: u64 = 0,
        tail_bytes: u64 = 0,
        kept_bytes: u64 = 0,
    };

    fn end(self: *Store) !End {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;
        return .{
            .position = self.file_count - 1,
            .offset = self.shard.writer.offset,
            .last_batch_id = self.shard.writer.last_batch_id,
            .total_bytes = self.shard.generation.index.total_bytes,
        };
    }

    /// Keeps live records, and all of the snapshot's last batch so IDs never go backwards.
    fn keepLive(self: *Store, job: *Job, output: *CompactionOutput, old: *Shard.Generation, position: usize, batch: Batch) !void {
        const start = batch.end_offset - commit.commit_len - batch.records.len;
        const first = job.moves.items.len;
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var read: usize = 0;
        var written: usize = 0;
        var count: u32 = 0;
        {
            self.shard.mutex.lockUncancelable(self.io);
            defer self.shard.mutex.unlock(self.io);
            while (read < batch.records.len) {
                const decoded = try entry.decodeVerified(batch.records[read..]);
                const bytes = batch.records[read..][0..decoded.consumed];
                const offset = start + read;
                read += decoded.consumed;
                const live = if (try old.index.get(decoded.entry.key)) |location|
                    location.segment == position and location.offset == offset
                else
                    false;
                if (!live and batch.id != job.keep_id) continue;
                if (live) try job.moves.append(self.allocator, .{ .segment = @intCast(position), .offset = offset, .to_segment = 0, .to_offset = written });
                @memcpy(job.filtered[written..][0..bytes.len], bytes);
                digest.update(bytes);
                written += bytes.len;
                count += 1;
            }
        }
        if (written == 0) return;
        const marker = try commit.marker(batch.id, count, written, digest.finalResult());
        @memcpy(job.filtered[written..][0..commit.commit_len], &marker);
        const placed = (try output.append(job.filtered[0 .. written + commit.commit_len])).?;
        const base = placed.end - written - commit.commit_len;
        for (job.moves.items[first..]) |*move| {
            move.to_segment = @intCast(placed.position);
            move.to_offset += base;
        }
        job.kept_bytes += written + commit.commit_len;
    }

    fn copyTail(self: *Store, tail: *Tail, target: End, generation: u64, ids: []u64, devices: []File, scratch: []u8) !u64 {
        var copied: u64 = 0;
        while (true) {
            const last = tail.position == target.position;
            const source = self.devices[tail.position];
            const stop = if (last) target.offset else try source.length();
            const slot = tail.first + tail.position - tail.start;
            if (stop > tail.offset) {
                while (tail.opened <= slot) try self.openTailSegment(tail, generation, ids, devices);
                const base = if (tail.position == tail.start) tail.base else 0;
                while (tail.offset < stop) {
                    const len: usize = @intCast(@min(stop - tail.offset, scratch.len));
                    try source.readExact(scratch[0..len], tail.offset);
                    try devices[slot].writeAll(scratch[0..len], tail.offset - base);
                    tail.offset += len;
                    copied += len;
                }
            }
            if (last) return copied;
            for (devices[tail.synced..tail.opened]) |device| try device.sync();
            tail.synced = tail.opened;
            tail.position += 1;
            tail.offset = segment.encoded_len;
        }
    }

    fn openTailSegment(self: *Store, tail: *Tail, generation: u64, ids: []u64, devices: []File) !void {
        const slot = tail.opened;
        if (slot == ids.len) return error.TooManySegments;
        ids[slot] = slot + 1;
        devices[slot] = .{ .handle = try files.createSegment(self.directory.dir, self.io, generation, ids[slot]), .io = self.io };
        tail.opened += 1;
        const header = try (segment.Header{ .generation = generation, .segment_id = ids[slot], .region = self.region }).encode();
        try devices[slot].writeAll(&header, 0);
    }

    fn remap(self: *Store, index: *const Index, moves: []const Move, snapshot: End, tail: Tail, generation: u64, ids: []u64) !Index {
        var next: Index = .{
            .allocator = self.allocator,
            .region = index.region,
            .generation = generation,
            .max_keys = index.max_keys,
            .stats = index.stats,
            .segment_ids = ids,
            .fingerprints = index.fingerprints,
            .last_batch_id = index.last_batch_id,
            .live_bytes = index.live_bytes,
            .entries = try index.entries.clone(self.allocator),
        };
        errdefer next.deinit();
        var locations = next.entries.valueIterator();
        while (locations.next()) |location| {
            if (location.segment < snapshot.position or (location.segment == snapshot.position and location.offset < snapshot.offset)) {
                const move = findMove(moves, location.segment, location.offset) orelse return error.IndexMismatch;
                location.segment = move.to_segment;
                location.offset = move.to_offset;
            } else {
                const piece = location.segment - snapshot.position;
                if (piece == 0) location.offset -= tail.base;
                location.segment = @intCast(tail.first + piece);
            }
        }
        return next;
    }

    fn findMove(moves: []const Move, position: u16, offset: u64) ?Move {
        var low: usize = 0;
        var high = moves.len;
        while (low < high) {
            const middle = (low + high) / 2;
            const move = moves[middle];
            if (move.segment < position or (move.segment == position and move.offset < offset)) low = middle + 1 else high = middle;
        }
        if (low == moves.len or moves[low].segment != position or moves[low].offset != offset) return null;
        return moves[low];
    }

    pub fn reclaim(self: *Store, generation: u64, ids: []const u64) !reclamation.Result {
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.shard.writer.failed) return error.WriterFailed;
        self.directory_mutex.lockUncancelable(self.io);
        defer self.directory_mutex.unlock(self.io);
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

        try self.commitBarrier();
    }

    pub fn close(self: *Store) !void {
        self.compact_mutex.lockUncancelable(self.io);
        defer self.compact_mutex.unlock(self.io);
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;

        const barrier_result = self.commitBarrier();
        const close_result = self.shard.close();
        self.release();
        try barrier_result;
        try close_result;
    }

    pub fn deinit(self: *Store) void {
        self.compact_mutex.lockUncancelable(self.io);
        defer self.compact_mutex.unlock(self.io);
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
        self.directory_mutex.lockUncancelable(self.io);
        defer self.directory_mutex.unlock(self.io);
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
