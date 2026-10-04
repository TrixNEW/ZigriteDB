const std = @import("std");

const lock = @import("../lock.zig");
const lz4 = @import("../compression/lz4.zig");
const write_module = @import("../batch/write.zig");
const WriteBatch = write_module.WriteBatch;
const Cache = @import("../cache/value.zig").Cache;
const frame = @import("../format/frame.zig");
const key_format = @import("../format/key.zig");
const Component = key_format.Component;
const Key = key_format.Key;
const KeyFilter = key_format.KeyFilter;
const Region = key_format.Region;
const manifest = @import("../format/manifest.zig");
const record = @import("../format/record.zig");
const segment = @import("../format/segment.zig");
const index_module = @import("../index/index.zig");
const Index = index_module.Index;
const Location = index_module.Location;
const File = @import("../io/file.zig").File;
const scan = @import("../recovery/scan.zig");
const Stats = @import("../stats.zig").Stats;
const crc = @import("../format/crc.zig");
const checkpoint = @import("../format/checkpoint.zig");
const CompactionOutput = @import("../storage/compaction_output.zig").CompactionOutput;
const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");
const publication = @import("../storage/publication.zig");
const reclamation = @import("../storage/reclamation.zig");

const Scanner = scan.FileScanner(File);

pub const Durability = enum { sync, buffered };

pub const Options = struct {
    max_keys: u32 = 65536,
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    /// Largest uncompressed frame.
    batch_buffer_size: usize = 1024 * 1024,
    durability: Durability = .buffered,
    /// 0 disables compression.
    compression_threshold: u32 = 256,
    stats: ?*Stats = null,
    cache: ?*Cache = null,
    skip_unchanged: bool = false,
    // Ask for compaction once live data drops below this share of a store this big.
    compact_min_bytes: u64 = 16 * 1024 * 1024,
    compact_live_percent: u8 = 50,

    pub fn validate(self: Options) !void {
        if (self.max_segments == 0 or self.max_segments > index_module.max_segments) return error.InvalidSegmentCount;
        if (self.batch_buffer_size < frame.header_len + record.overhead or self.batch_buffer_size > frame.max_bytes + frame.header_len)
            return error.InvalidBufferSize;
        if (self.max_segment_size < segment.encoded_len + frame.header_len + record.overhead or
            self.max_segment_size > index_module.max_segment_size) return error.InvalidSegmentSize;
        if (self.compact_live_percent > 100) return error.InvalidArgument;
    }
};

test "corrupt compaction tail fails while the writer lock is held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var store = try Store.create(allocator, io, tmp.dir, .{ .dimension = 0, .x = 0, .z = 0 }, .{});
    defer store.deinit();
    try store.generation.devices[0].writeAll("X", 0);
    var scratch = try allocator.alloc(u8, 256);
    defer allocator.free(scratch);
    var tail: Store.Tail = .{ .position = 0, .offset = segment.encoded_len };
    var output: CompactionOutput = undefined;
    lock.lockUncancelable(&store.writer, io);
    defer store.writer.unlock(io);
    try std.testing.expectError(error.InvalidMagic, store.copyTail(store.generation, &tail, &output, &store.generation.index, &scratch, true));
    try std.testing.expect(store.failed);
}

test "flush releases the commit mutex before waiting for the writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var store = try Store.create(std.testing.allocator, io, tmp.dir, .{ .dimension = 0, .x = 0, .z = 0 }, .{});
    defer store.deinit();
    const Flusher = struct {
        fn run(target: *Store, failure: *?anyerror) void {
            target.flush() catch |err| {
                failure.* = err;
            };
        }
    };
    var failure: ?anyerror = null;
    lock.lockUncancelable(&store.writer, io);
    const thread = std.Thread.spawn(.{}, Flusher.run, .{ &store, &failure }) catch |err| {
        store.writer.unlock(io);
        return err;
    };
    while (store.writer.state.load(.acquire) != .contended) std.atomic.spinLoopHint();
    const available = store.commit_mutex.tryLock();
    if (available) store.commit_mutex.unlock(io);
    store.writer.unlock(io);
    thread.join();
    try std.testing.expect(available);
    try std.testing.expectEqual(@as(?anyerror, null), failure);
}

pub const AppendResult = struct {
    batch_id: u64,
    start: u64,
    end: u64,
    synced: bool,
};

pub const ReadRequest = struct {
    key: Key,
    output: []u8,
};

pub const ReadStatus = enum(u8) { ok, not_found, buffer_too_small };

pub const ReadResult = struct {
    status: ReadStatus = .not_found,
    required: usize = 0,
    value: []const u8 = &.{},
};

pub const ChunkRecord = struct {
    component: Component,
    subchunk_y: i8,
    value: []const u8,
};

pub const ChunkResult = struct {
    count: usize,
    required: usize,
};

pub const CompactionResult = struct {
    generation: u64,
    segment_count: usize,
    source_bytes: u64,
    output_bytes: u64,
    cleanup: reclamation.Result,
};

pub const max_batch_keys = 256;

const Generation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    index: Index,
    devices: []File,
    segment_ids: []u64,
    count: usize,
    readers: std.atomic.Value(usize) = .init(0),

    fn destroy(self: *Generation) void {
        for (self.devices[0..self.count]) |device| device.handle.close(self.io);
        self.index.deinit();
        self.allocator.free(self.devices);
        self.allocator.free(self.segment_ids);
        self.allocator.destroy(self);
    }
};

// Arrays live here because ReleaseSafe fills stack arrays on every call.
const Buffer = struct {
    bytes: []u8 = &.{},
    encoder: lz4.Encoder = .{},
    builders: [write_module.max_group_batches]frame.Builder = undefined,
    batches: [write_module.max_group_batches]scan.Batch = undefined,
    ids: [write_module.max_group_batches]u64 = undefined,
    entries: [Store.inline_records]index_module.Entry = undefined,
    wants: [Store.inline_records]Store.Want = undefined,
    order: [Store.inline_records]u16 = undefined,
    targets: [Store.inline_records]u16 = undefined,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: Directory,
    region: Region,
    salt: u64,
    options: Options,
    base_batch_id: u64,

    // Serializes appends and guards the fields below.
    writer: std.Io.Mutex = .init,
    segment_id: u64,
    offset: u64,
    synced_offset: u64,
    // Bumped when the active segment changes.
    epoch: u64 = 0,
    failed: bool = false,
    closed: bool = false,

    // Exclusive to change the index or swap generations.
    table: std.Io.RwLock = .init,
    generation: *Generation,
    closing: bool = false,
    idle: std.Io.Condition = .init,
    idle_mutex: std.Io.Mutex = .init,
    drainers: std.atomic.Value(usize) = .init(0),

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

    pool_mutex: std.Io.Mutex = .init,
    pool: std.ArrayListUnmanaged(*Buffer) = .empty,

    // What INDEX covers, so close only rewrites it after changes.
    checkpointed: Cover = .{},

    const pool_limit = 8;
    const prefetch_limit = 64 * 1024 * 1024;
    const max_pooled_len = 1024 * 1024;

    pub fn create(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, region: Region, options: Options) !Store {
        try options.validate();
        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();
        try discardUnpublished(&directory);
        var iterator = directory.dir.iterate();
        if (try iterator.next(io) != null) return error.DirectoryNotEmpty;

        const salt = segment.newSalt(io);
        const handle = try files.createSegment(directory.dir, io, 1, 1);
        const device: File = .{ .handle = handle, .io = io };
        var device_owned = true;
        errdefer if (device_owned) {
            handle.close(io);
            files.removeSegment(directory.dir, io, 1, 1) catch {};
            directory.syncEntries() catch {};
        };
        const header = try (segment.Header{ .segment_id = 1, .generation = 1, .region = region, .salt = salt }).encode();
        try device.writeAll(&header, 0);
        try device.sync();

        var index = try Index.init(allocator, region, 1, options.max_keys);
        index.stats = options.stats;
        index.fingerprints = options.skip_unchanged;
        const generation = newGeneration(allocator, io, options.max_segments) catch |err| {
            index.deinit();
            return err;
        };
        generation.index = index;
        device_owned = false;
        generation.devices[0] = device;
        generation.segment_ids[0] = 1;
        generation.count = 1;
        errdefer generation.destroy();

        var pool: std.ArrayListUnmanaged(*Buffer) = try .initCapacity(allocator, pool_limit);
        errdefer pool.deinit(allocator);
        var buffer: [manifest.header_len + 12]u8 = undefined;
        const bytes = try (manifest.Manifest{ .generation = 1, .region = region, .segments = &.{1}, .salt = salt }).encode(&buffer);
        var publisher: publication.Publisher(*Directory) = .{ .backend = &directory };
        try publisher.publish(bytes);

        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .region = region,
            .salt = salt,
            .options = options,
            .base_batch_id = 0,
            .segment_id = 1,
            .offset = segment.encoded_len,
            .synced_offset = segment.encoded_len,
            .generation = generation,
            .pool = pool,
        };
    }

    /// Callers set `index` afterwards.
    fn newGeneration(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !*Generation {
        const devices = try allocator.alloc(File, capacity);
        errdefer allocator.free(devices);
        const ids = try allocator.alloc(u64, capacity);
        errdefer allocator.free(ids);
        const generation = try allocator.create(Generation);
        generation.* = .{ .allocator = allocator, .io = io, .index = undefined, .devices = devices, .segment_ids = ids, .count = 0 };
        return generation;
    }

    /// A first segment without a manifest is a creation that never published.
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

    /// Removes segments left by an unfinished compaction or rotation.
    fn discardUnfinished(directory: *Directory, current: u64, active: u64) !void {
        var removed = false;
        var iterator = directory.dir.iterate();
        while (try iterator.next(directory.io)) |item| {
            if (item.kind != .file or item.name.len != 41 or !std.mem.endsWith(u8, item.name, ".segment") or item.name[16] != '-') continue;
            const generation = std.fmt.parseInt(u64, item.name[0..16], 16) catch continue;
            const id = std.fmt.parseInt(u64, item.name[17..33], 16) catch continue;
            const unpublished = (generation == current and id > active) or generation == current +% 1;
            if (!unpublished) continue;
            try directory.dir.deleteFile(directory.io, item.name);
            removed = true;
        }
        if (removed) try directory.syncEntries();
    }

    pub fn readManifest(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, ids: []u64) !struct { manifest.Manifest, []u8 } {
        const handle = try files.openManifest(dir, io);
        defer handle.close(io);
        const file: File = .{ .handle = handle, .io = io };
        const length = try file.length();
        if (length > manifest.max_encoded_len) return error.ManifestTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(bytes);
        try file.readExact(bytes, 0);
        if (manifest.peekVersion(bytes)) |found| if (found < manifest.version) return error.NeedsMigration;
        return .{ try manifest.decode(bytes, ids), bytes };
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !Store {
        try options.validate();
        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();
        if (directory.dir.statFile(io, "MANIFEST.tmp", .{ .follow_symlinks = false })) |_| {
            return error.NeedsRecovery;
        } else |err| if (err != error.FileNotFound) return err;

        const ids = try allocator.alloc(u64, manifest.max_segments);
        defer allocator.free(ids);
        const metadata, const manifest_bytes = try readManifest(allocator, io, directory.dir, ids);
        defer allocator.free(manifest_bytes);
        if (metadata.segments.len > options.max_segments) return error.InvalidSegmentCount;
        try discardUnfinished(&directory, metadata.generation, metadata.segments[metadata.segments.len - 1]);

        var index = try Index.init(allocator, metadata.region, metadata.generation, options.max_keys);
        index.stats = options.stats;
        index.fingerprints = options.skip_unchanged;
        index.order.last_batch_id = metadata.base_batch_id;
        const generation = newGeneration(allocator, io, options.max_segments) catch |err| {
            index.deinit();
            return err;
        };
        generation.index = index;
        errdefer generation.destroy();
        for (metadata.segments, 0..) |id, position| {
            const active = position == metadata.segments.len - 1;
            generation.devices[position] = .{ .handle = try files.openSegment(directory.dir, io, metadata.generation, id, active), .io = io };
            generation.segment_ids[position] = id;
            generation.count += 1;
            _ = try Scanner.init(generation.devices[position], .{
                .segment_id = id,
                .generation = metadata.generation,
                .region = metadata.region,
                .salt = metadata.salt,
            }, if (active) .active else .sealed, .{}, options.max_segment_size);
        }

        const covered = try loadCheckpoint(allocator, io, &directory, &generation.index, generation.devices[0..generation.count], metadata, options);
        const start: Cover = covered orelse .{ .generation = metadata.generation, .segments = 1, .offset = segment.encoded_len };
        const active = generation.devices[generation.count - 1];
        const end = if (start.segments == generation.count and start.offset == try active.length()) start.offset else blk: {
            var scratch = try allocator.alloc(u8, options.batch_buffer_size);
            defer allocator.free(scratch);
            break :blk try replay(allocator, &generation.index, generation.devices[0..generation.count], metadata, options, &scratch, start.segments - 1, start.offset);
        };
        if (try active.length() != end) return error.FileChanged;
        // An exact INDEX means the last close synced everything.
        const clean = if (covered) |c| c.segments == generation.count and c.offset == end else false;
        if (!clean) {
            try directory.syncEntries();
            try active.sync();
        }
        // Nothing was read, so prefetch like a replay would.
        if (covered != null) {
            var budget: u64 = prefetch_limit;
            var i = generation.count;
            while (i > 0 and budget > 0) {
                i -= 1;
                const len = @min(budget, try generation.devices[i].length());
                generation.devices[i].willNeed(len);
                budget -= len;
            }
        }
        var pool: std.ArrayListUnmanaged(*Buffer) = try .initCapacity(allocator, pool_limit);
        errdefer pool.deinit(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .region = metadata.region,
            .salt = metadata.salt,
            .options = options,
            .base_batch_id = metadata.base_batch_id,
            .segment_id = metadata.segments[metadata.segments.len - 1],
            .offset = end,
            .synced_offset = end,
            .generation = generation,
            .pool = pool,
            .checkpointed = covered orelse .{},
        };
    }

    const Cover = struct {
        generation: u64 = 0,
        segments: usize = 0,
        offset: u64 = 0,
    };

    /// Any doubt leaves the index empty for a full replay.
    fn loadCheckpoint(allocator: std.mem.Allocator, io: std.Io, directory: *Directory, index: *Index, devices: []const File, metadata: manifest.Manifest, options: Options) !?Cover {
        const cover = readCheckpoint(allocator, io, directory, index, devices, metadata, options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (cover == null) {
            const fresh = try Index.init(allocator, index.region, index.generation, index.max_keys);
            var old = index.*;
            index.* = fresh;
            index.stats = old.stats;
            index.fingerprints = old.fingerprints;
            index.order = .{ .last_batch_id = metadata.base_batch_id };
            old.deinit();
        }
        return cover;
    }

    fn readCheckpoint(allocator: std.mem.Allocator, io: std.Io, directory: *Directory, index: *Index, devices: []const File, metadata: manifest.Manifest, options: Options) !Cover {
        const handle = try files.openRegularFile(directory.dir, io, checkpoint.name);
        defer handle.close(io);
        const file: File = .{ .handle = handle, .io = io };
        const length = try file.length();
        if (length < checkpoint.header_len or length > checkpoint.header_len + manifest.max_segments * 8 + 2048 + @as(u64, options.max_keys) * 28 + 4)
            return error.InvalidLength;
        const bytes = try allocator.alloc(u8, @intCast(length));
        defer allocator.free(bytes);
        try file.readExact(bytes, 0);

        const header = try checkpoint.Header.read(bytes[0..checkpoint.header_len]);
        const valid = header.generation == metadata.generation and header.salt == metadata.salt and
            header.segments != 0 and header.segments <= metadata.segments.len and header.entries <= options.max_keys and
            header.len() == bytes.len and (header.fingerprints or !options.skip_unchanged);
        if (!valid) return error.StaleCheckpoint;
        const body = bytes[checkpoint.header_len..];
        if (std.mem.readInt(u32, body[body.len - 4 ..][0..4], .little) != crc.hash(body[0 .. body.len - 4])) return error.ChecksumMismatch;

        var at: usize = 0;
        for (metadata.segments[0..header.segments]) |id| {
            if (std.mem.readInt(u64, body[at..][0..8], .little) != id) return error.StaleCheckpoint;
            at += 8;
        }
        var ends: [index_module.max_segments]u64 = undefined;
        for (devices[0..header.segments], ends[0..header.segments]) |device, *e| e.* = try device.length();
        const last = header.segments - 1;
        if (header.offset < segment.encoded_len or header.offset > ends[last]) return error.StaleCheckpoint;
        ends[last] = header.offset;

        const counts = body[at..][0 .. 1024 * 2];
        at += counts.len;
        const entry_len = header.entryLen();
        const locals = try allocator.alloc(u16, std.math.maxInt(u16));
        defer allocator.free(locals);
        const locations = try allocator.alloc(Location, std.math.maxInt(u16));
        defer allocator.free(locations);
        var total: usize = 0;
        for (0..1024) |slot| {
            const count = std.mem.readInt(u16, counts[slot * 2 ..][0..2], .little);
            total += count;
            if (total > header.entries) return error.StaleCheckpoint;
            for (locals[0..count], locations[0..count]) |*k, *location| {
                k.*, location.* = try checkpoint.readEntry(body[at..][0..entry_len], header.fingerprints);
                at += entry_len;
                if (location.segment >= header.segments or location.offset < segment.encoded_len or
                    @as(u64, location.offset) + location.recordLen() > ends[location.segment]) return error.StaleCheckpoint;
            }
            try index.loadChunk(@intCast(slot), locals[0..count], locations[0..count]);
        }
        if (total != header.entries) return error.StaleCheckpoint;
        index.order = .{ .last_batch_id = header.last_batch_id, .seen_batch = header.seen_batch };
        index.total_bytes = header.total_bytes;
        return .{ .generation = header.generation, .segments = header.segments, .offset = header.offset };
    }

    /// Failure only costs a slower open.
    fn writeCheckpoint(self: *Store) void {
        const generation = self.generation;
        const cover: Cover = .{ .generation = generation.index.generation, .segments = generation.count, .offset = self.offset };
        if (std.meta.eql(cover, self.checkpointed) or self.synced_offset != self.offset) return;
        self.saveCheckpoint(cover) catch {
            self.directory.dir.deleteFile(self.io, checkpoint.name ++ ".tmp") catch {};
            return;
        };
        self.checkpointed = cover;
    }

    fn saveCheckpoint(self: *Store, cover: Cover) !void {
        const index = &self.generation.index;
        const fingerprints = index.fingerprints;
        const header: checkpoint.Header = .{
            .fingerprints = fingerprints,
            .generation = cover.generation,
            .salt = self.salt,
            .segments = @intCast(cover.segments),
            .entries = index.count,
            .offset = cover.offset,
            .last_batch_id = index.order.last_batch_id,
            .total_bytes = index.total_bytes,
            .seen_batch = index.order.seen_batch,
        };
        const handle = try self.directory.dir.createFile(self.io, checkpoint.name ++ ".tmp", .{ .truncate = true });
        defer handle.close(self.io);
        const file: File = .{ .handle = handle, .io = self.io };
        // Keeps close free of allocations.
        var buffer: [16 * 1024]u8 = undefined;
        var writer: Spill = .{ .file = file, .buffer = &buffer, .offset = checkpoint.header_len };
        for (self.generation.segment_ids[0..cover.segments]) |id| try writer.int(u64, id);
        for (index.chunks) |c| try writer.int(u16, c.len);
        const entry_len = header.entryLen();
        for (index.chunks) |c| {
            for (c.keys(), c.locations()) |local, location| {
                const bytes = try writer.reserve(entry_len);
                checkpoint.writeEntry(bytes, local, location, fingerprints);
            }
        }
        try writer.flush();
        var tail: [4]u8 = undefined;
        std.mem.writeInt(u32, &tail, ~writer.checksum, .little);
        try file.writeAll(&tail, writer.offset);
        var head: [checkpoint.header_len]u8 = undefined;
        header.write(&head);
        try file.writeAll(&head, 0);
        try self.directory.dir.rename(checkpoint.name ++ ".tmp", self.directory.dir, checkpoint.name, self.io);
    }

    const Spill = struct {
        file: File,
        buffer: []u8,
        used: usize = 0,
        offset: u64,
        checksum: u32 = 0xffff_ffff,

        fn reserve(self: *Spill, len: usize) ![]u8 {
            if (self.buffer.len - self.used < len) try self.flush();
            defer self.used += len;
            return self.buffer[self.used..][0..len];
        }

        fn int(self: *Spill, comptime T: type, value: T) !void {
            std.mem.writeInt(T, (try self.reserve(@sizeOf(T)))[0..@sizeOf(T)], value, .little);
        }

        fn flush(self: *Spill) !void {
            self.checksum = crc.update(self.checksum, self.buffer[0..self.used]);
            try self.file.writeAll(self.buffer[0..self.used], self.offset);
            self.offset += self.used;
            self.used = 0;
        }
    };

    /// Returns the active segment's end.
    fn replay(allocator: std.mem.Allocator, index: *Index, devices: []const File, metadata: manifest.Manifest, options: Options, scratch: *[]u8, position: usize, offset: u64) !u64 {
        var end: u64 = offset;
        for (devices[position..], metadata.segments[position..], position..) |device, id, at| {
            const active = at == devices.len - 1;
            var scanner = try Scanner.init(device, .{
                .segment_id = id,
                .generation = metadata.generation,
                .region = metadata.region,
                .salt = metadata.salt,
            }, if (active) .active else .sealed, index.order, options.max_segment_size);
            if (at == position) try scanner.seek(offset);
            while (try scanner.nextGrowing(allocator, scratch)) |batch| try index.apply(batch, at);
            if (scanner.has_tail) return error.NeedsRecovery;
            end = scanner.offset;
        }
        return end;
    }

    /// Durable on return only with `.sync`.
    pub fn write(self: *Store, batch: WriteBatch) !AppendResult {
        return self.commit(&.{batch}, self.options.durability == .sync);
    }

    /// Durable on return whatever the durability.
    pub fn writeGroup(self: *Store, batches: []const WriteBatch) !AppendResult {
        return self.commit(batches, true);
    }

    fn commit(self: *Store, batches: []const WriteBatch, durable: bool) !AppendResult {
        // Callers must not race close.
        if (self.closed) return error.Closed;
        const size = try write_module.validateGroup(batches);
        if (size > self.options.batch_buffer_size) return error.BufferTooSmall;
        if (!batches[0].region().eql(self.region)) return error.RegionMismatch;
        if (size > self.options.max_segment_size - segment.encoded_len) return error.BatchTooLarge;

        var bound: usize = 0;
        for (batches) |batch| bound += batch.bound();
        const buffer = try self.borrow(bound);
        defer self.giveBack(buffer);

        const builders = &buffer.builders;
        const ids = &buffer.ids;
        var used: usize = 0;
        var kept: usize = 0;
        for (batches) |batch| {
            var builder = frame.Builder.init(buffer.bytes[used..]);
            const encoder: ?*lz4.Encoder = if (self.options.compression_threshold == 0) null else &buffer.encoder;
            for (batch.entries) |entry| try builder.add(entry.key.slot(), entry.key.local(), entry.value, encoder, self.options.compression_threshold);
            builders[kept] = builder;
            ids[kept] = batch.id;
            kept += 1;
            used += builder.len;
        }
        for (builders[1..kept], builders[0 .. kept - 1]) |*next, previous| {
            std.debug.assert(next.buffer.ptr == previous.buffer.ptr + previous.len);
        }
        return self.append(buffer.bytes[0..used], builders[0..kept], ids[0..kept], buffer.batches[0..kept], durable);
    }

    fn append(self: *Store, input: []u8, builders: []frame.Builder, ids: []const u64, batches: []scan.Batch, durable: bool) !AppendResult {
        const result: AppendResult, const ticket: ?u64 = blk: {
            try lock.lock(&self.writer, self.io);
            defer self.writer.unlock(self.io);
            if (self.closed) return error.Closed;
            if (self.failed) return error.WriterFailed;

            // ponytail: groups keep every frame until filtering tracks earlier changes.
            const span = if (self.options.skip_unchanged and builders.len == 1) filtered: {
                try self.dropUnchanged(&builders[0]);
                if (builders[0].count == 0) break :blk .{
                    .{ .batch_id = self.generation.index.lastBatchId(), .start = self.offset, .end = self.offset, .synced = false },
                    if (durable) self.nextTicket() else null,
                };
                break :filtered input[0..builders[0].len];
            } else input;

            if (span.len > self.options.max_segment_size - self.offset) try self.rotate();
            var last = self.generation.index.lastBatchId();
            var at = self.offset;
            for (builders, ids, batches) |*builder, requested, *batch| {
                const id = if (requested == 0) std.math.add(u64, last, 1) catch return error.BatchOrder else requested;
                if (id <= last) return error.BatchOrder;
                last = id;
                const bytes = builder.finish(.batch, id, self.salt);
                batch.* = .{ .header = builder.header(.batch, id), .bytes = bytes, .offset = at };
                at += bytes.len;
            }

            const prepared = prep: {
                self.table.lockUncancelable(self.io);
                defer self.table.unlock(self.io);
                break :prep try self.generation.index.prepare(batches, self.generation.count - 1);
            };
            const start = self.offset;
            self.generation.devices[self.generation.count - 1].writeAll(span, start) catch |err| {
                self.failed = true;
                return err;
            };
            {
                self.table.lockUncancelable(self.io);
                defer self.table.unlock(self.io);
                self.generation.index.publish(prepared);
            }
            self.offset = start + span.len;
            self.checkStale();
            const ticket = if (durable) self.nextTicket() else null;
            break :blk .{ .{ .batch_id = last, .start = start, .end = self.offset, .synced = false }, ticket };
        };
        if (builders[0].count != 0) self.countWrites(builders);
        var done = result;
        if (ticket) |t| {
            try self.waitDurable(t);
            done.synced = true;
        }
        return done;
    }

    fn dropUnchanged(self: *Store, builder: *frame.Builder) !void {
        var kept: frame.Builder = .{ .buffer = builder.buffer };
        var offset: usize = frame.header_len;
        var skipped: u64 = 0;
        while (offset < builder.len) {
            const header = record.Header.read(builder.buffer[offset..][0..record.header_len]) catch unreachable;
            const len = record.overhead + header.stored_len;
            const bytes = builder.buffer[offset..][0..len];
            offset += len;
            if (!self.repeated(builder, header) and try self.unchanged(header, bytes[record.header_len..][0..header.stored_len])) {
                skipped += 1;
                continue;
            }
            // Moving left never overwrites records still to be read.
            std.mem.copyForwards(u8, kept.buffer[kept.len..][0..len], bytes);
            kept.checksums = crc.update(kept.checksums, kept.buffer[kept.len + len - 4 ..][0..4]);
            kept.len += len;
            kept.count += 1;
        }
        builder.* = kept;
        if (self.options.stats) |s| _ = s.unchanged_write_skips.fetchAdd(skipped, .monotonic);
    }

    /// Repeated keys are kept so the last one wins.
    fn repeated(_: *Store, builder: *const frame.Builder, header: record.Header) bool {
        var seen: usize = 0;
        var offset: usize = frame.header_len;
        while (offset < builder.len) {
            const other = record.Header.read(builder.buffer[offset..][0..record.header_len]) catch unreachable;
            if (other.slot == header.slot and other.local == header.local) seen += 1;
            offset += record.overhead + other.stored_len;
        }
        return seen > 1;
    }

    fn unchanged(self: *Store, header: record.Header, stored: []const u8) !bool {
        var pinned = (try self.pinLocal(header.slot, header.local)) orelse return header.delete;
        defer self.unpin(pinned.generation);
        if (header.delete) return false;
        const location = pinned.location;
        if (location.stored_len != header.stored_len or location.raw_len != header.raw_len or
            location.compression != header.compression or location.fingerprint != index_module.fingerprint(header.compression, stored)) return false;
        const scratch = try self.borrow(location.recordLen());
        defer self.giveBack(scratch);
        const bytes = scratch.bytes[0..location.recordLen()];
        try pinned.generation.devices[location.segment].readExact(bytes, location.offset);
        const decoded = try checkRecord(bytes, location, header.slot, header.local);
        return std.mem.eql(u8, decoded.value, stored);
    }

    fn countWrites(self: *Store, builders: []const frame.Builder) void {
        const s = self.options.stats orelse return;
        _ = s.writes.fetchAdd(builders.len, .monotonic);
        for (builders) |builder| {
            _ = s.records_written.fetchAdd(builder.count, .monotonic);
            var offset: usize = frame.header_len;
            var raw: u64 = 0;
            var stored: u64 = 0;
            while (offset < builder.len) {
                const header = record.Header.read(builder.buffer[offset..][0..record.header_len]) catch unreachable;
                raw += header.raw_len;
                stored += header.stored_len;
                offset += record.overhead + header.stored_len;
            }
            _ = s.raw_bytes_written.fetchAdd(raw, .monotonic);
            _ = s.compressed_bytes_written.fetchAdd(stored, .monotonic);
        }
    }

    fn checkStale(self: *Store) void {
        const index = &self.generation.index;
        if (index.total_bytes < self.options.compact_min_bytes or index.live_bytes == index.total_bytes) return;
        const stale = index.live_bytes * 100 < index.total_bytes * self.options.compact_live_percent;
        const crowded = self.generation.count * 4 >= self.options.max_segments * 3;
        if (stale or crowded) self.compaction_hint.store(true, .monotonic);
    }

    /// True once each time the store goes stale.
    pub fn wantsCompaction(self: *Store) bool {
        return self.compaction_hint.swap(false, .monotonic);
    }

    /// Writer lock held.
    fn rotate(self: *Store) !void {
        const generation = self.generation;
        if (generation.count == self.options.max_segments) return error.TooManySegments;
        const id = std.math.add(u64, self.segment_id, 1) catch return error.SegmentIdExhausted;
        try self.syncActive();

        // Failures stop writes.
        errdefer self.failed = true;
        const handle = try files.createSegment(self.directory.dir, self.io, generation.index.generation, id);
        const device: File = .{ .handle = handle, .io = self.io };
        errdefer handle.close(self.io);
        // Once publishing starts the manifest may name the file.
        var publishing = false;
        errdefer if (!publishing) files.removeSegment(self.directory.dir, self.io, generation.index.generation, id) catch {};
        const header = try (segment.Header{ .segment_id = id, .generation = generation.index.generation, .region = self.region, .salt = self.salt }).encode();
        try device.writeAll(&header, 0);
        try device.sync();

        generation.segment_ids[generation.count] = id;
        var buffer: [manifest.max_encoded_len]u8 = undefined;
        const bytes = try self.manifestBytes(&buffer, generation.index.generation, generation.segment_ids[0 .. generation.count + 1], self.base_batch_id);
        {
            lock.lockUncancelable(&self.directory_mutex, self.io);
            defer self.directory_mutex.unlock(self.io);
            var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
            publishing = true;
            try publisher.publish(bytes);
        }
        {
            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            generation.devices[generation.count] = device;
            generation.count += 1;
        }
        self.segment_id = id;
        self.offset = segment.encoded_len;
        self.synced_offset = segment.encoded_len;
        self.epoch += 1;
        if (self.options.stats) |s| _ = s.segment_rotations.fetchAdd(1, .monotonic);
    }

    fn manifestBytes(self: *Store, buffer: []u8, generation: u64, ids: []const u64, base: u64) ![]u8 {
        return (manifest.Manifest{ .generation = generation, .region = self.region, .segments = ids, .base_batch_id = base, .salt = self.salt }).encode(buffer);
    }

    /// Writer lock held.
    fn syncActive(self: *Store) !void {
        if (self.synced_offset == self.offset) return;
        self.timedSync(self.generation.devices[self.generation.count - 1]) catch |err| {
            self.failed = true;
            return err;
        };
        self.synced_offset = self.offset;
    }

    fn timedSync(self: *Store, device: File) !void {
        const started: ?std.Io.Clock.Timestamp = if (self.options.stats != null) std.Io.Clock.Timestamp.now(self.io, .awake) else null;
        try device.sync();
        if (self.options.stats) |s| {
            _ = s.fsync_count.fetchAdd(1, .monotonic);
            if (started) |t| _ = s.fsync_duration_ns.fetchAdd(@intCast(t.untilNow(self.io).raw.nanoseconds), .monotonic);
        }
    }

    fn nextTicket(self: *Store) u64 {
        lock.lockUncancelable(&self.commit_mutex, self.io);
        defer self.commit_mutex.unlock(self.io);
        self.appended_ticket += 1;
        return self.appended_ticket;
    }

    /// One waiter syncs for everyone appended before it started.
    fn waitDurable(self: *Store, ticket: u64) !void {
        lock.lockUncancelable(&self.commit_mutex, self.io);
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
            const result = self.syncAppended();
            lock.lockUncancelable(&self.commit_mutex, self.io);
            self.syncing = false;
            if (result) |_| self.synced_ticket = target else |err| self.commit_error = err;
            self.committed.broadcast(self.io);
        }
    }

    /// Appends continue during the fsync.
    fn syncAppended(self: *Store) !void {
        const generation, const device, const epoch, const offset = blk: {
            try lock.lock(&self.writer, self.io);
            defer self.writer.unlock(self.io);
            if (self.closed) return error.Closed;
            if (self.failed) return error.WriterFailed;
            if (self.synced_offset == self.offset) return;
            const generation = self.generation;
            _ = generation.readers.fetchAdd(1, .seq_cst);
            break :blk .{ generation, generation.devices[generation.count - 1], self.epoch, self.offset };
        };
        defer self.unpin(generation);
        const result = self.timedSync(device);
        lock.lockUncancelable(&self.writer, self.io);
        defer self.writer.unlock(self.io);
        result catch |err| {
            self.failed = true;
            return err;
        };
        // Rotation and compaction sync what they replace.
        if (self.epoch == epoch and offset > self.synced_offset) self.synced_offset = offset;
    }

    fn commitBarrier(self: *Store) !void {
        lock.lockUncancelable(&self.commit_mutex, self.io);
        defer self.commit_mutex.unlock(self.io);
        defer self.committed.broadcast(self.io);
        while (self.syncing) self.committed.waitUncancelable(self.io, &self.commit_mutex);
        if (self.commit_error) |err| return err;
        self.syncing = true;
        const target = self.appended_ticket;
        // Appends take writer before commit_mutex; never wait for writer while holding it.
        self.commit_mutex.unlock(self.io);
        const result = self.syncAppended();
        lock.lockUncancelable(&self.commit_mutex, self.io);
        self.syncing = false;
        result catch |err| {
            self.commit_error = err;
            return err;
        };
        self.synced_ticket = target;
    }

    pub fn flush(self: *Store) !void {
        if (self.closed) return error.Closed;
        return self.commitBarrier();
    }

    const Pinned = struct {
        generation: *Generation,
        location: Location,
    };

    fn pinLocal(self: *Store, slot: u10, local: u16) !?Pinned {
        try self.table.lockShared(self.io);
        defer self.table.unlockShared(self.io);
        if (self.closing) return error.Closed;
        const generation = self.generation;
        const location = generation.index.lookup(slot, local) orelse return null;
        if (location.segment >= generation.count) return error.IndexMismatch;
        _ = generation.readers.fetchAdd(1, .seq_cst);
        return .{ .generation = generation, .location = location };
    }

    // Each side updates its counter before reading the other's, so no wakeup is missed.
    fn unpin(self: *Store, generation: *Generation) void {
        if (generation.readers.fetchSub(1, .seq_cst) != 1 or self.drainers.load(.seq_cst) == 0) return;
        lock.lockUncancelable(&self.idle_mutex, self.io);
        defer self.idle_mutex.unlock(self.io);
        self.idle.broadcast(self.io);
    }

    fn waitReaders(self: *Store, generation: *Generation) void {
        _ = self.drainers.fetchAdd(1, .seq_cst);
        defer _ = self.drainers.fetchSub(1, .seq_cst);
        lock.lockUncancelable(&self.idle_mutex, self.io);
        defer self.idle_mutex.unlock(self.io);
        while (generation.readers.load(.seq_cst) != 0) self.idle.waitUncancelable(self.io, &self.idle_mutex);
    }

    fn borrow(self: *Store, len: usize) !*Buffer {
        const buffer = blk: {
            lock.lockUncancelable(&self.pool_mutex, self.io);
            defer self.pool_mutex.unlock(self.io);
            break :blk self.pool.pop();
        } orelse create: {
            const fresh = try self.allocator.create(Buffer);
            fresh.* = .{};
            break :create fresh;
        };
        self.reserve(buffer, len) catch |err| {
            self.allocator.free(buffer.bytes);
            self.allocator.destroy(buffer);
            return err;
        };
        return buffer;
    }

    fn reserve(self: *Store, buffer: *Buffer, len: usize) !void {
        if (buffer.bytes.len >= len) return;
        self.allocator.free(buffer.bytes);
        buffer.bytes = &.{};
        buffer.bytes = try self.allocator.alloc(u8, @max(len, 64 * 1024));
    }

    fn giveBack(self: *Store, buffer: *Buffer) void {
        if (buffer.bytes.len <= max_pooled_len) {
            lock.lockUncancelable(&self.pool_mutex, self.io);
            defer self.pool_mutex.unlock(self.io);
            if (self.pool.items.len < pool_limit) return self.pool.appendAssumeCapacity(buffer);
        }
        self.allocator.free(buffer.bytes);
        self.allocator.destroy(buffer);
    }

    fn checkRecord(bytes: []const u8, location: Location, slot: u10, local: u16) !record.Decoded {
        const decoded = try record.decode(bytes);
        const header = decoded.header;
        const same = decoded.len == bytes.len and !header.delete and header.slot == slot and header.local == local and
            header.stored_len == location.stored_len and header.raw_len == location.raw_len and header.compression == location.compression;
        if (!same) return error.IndexMismatch;
        return decoded;
    }

    fn decodeInto(decoded: record.Decoded, output: []u8) ![]const u8 {
        const raw_len = decoded.header.raw_len;
        if (output.len < raw_len) return error.BufferTooSmall;
        switch (decoded.header.compression) {
            .lz4 => return lz4.decompress(decoded.value, output, raw_len),
            .none => {
                @memcpy(output[0..raw_len], decoded.value);
                return output[0..raw_len];
            },
        }
    }

    pub fn get(self: *Store, key: Key, output: []u8) !?[]const u8 {
        var required: usize = 0;
        return self.getSized(key, output, &required);
    }

    pub fn getSized(self: *Store, key: Key, output: []u8, required: *usize) !?[]const u8 {
        required.* = 0;
        if (self.options.stats) |s| _ = s.get_calls.fetchAdd(1, .monotonic);
        if (!key.region().eql(self.region)) return error.RegionMismatch;
        try key.validate();
        const pinned = (try self.pinLocal(key.slot(), key.local())) orelse return null;
        defer self.unpin(pinned.generation);
        const location = pinned.location;
        required.* = location.raw_len;
        if (output.len < location.raw_len) return error.BufferTooSmall;
        if (self.options.cache) |cache| if (cache.get(self.io, key, location.batch_id, output)) |value| return value;

        const scratch = try self.borrow(location.recordLen());
        defer self.giveBack(scratch);
        const bytes = scratch.bytes[0..location.recordLen()];
        try pinned.generation.devices[location.segment].readExact(bytes, location.offset);
        self.countRead(bytes.len);
        const value = try decodeInto(try checkRecord(bytes, location, key.slot(), key.local()), output);
        if (self.options.cache) |cache| cache.put(self.io, key, location.batch_id, value);
        return value;
    }

    fn countRead(self: *Store, len: usize) void {
        const s = self.options.stats orelse return;
        _ = s.disk_reads.fetchAdd(1, .monotonic);
        _ = s.bytes_read.fetchAdd(len, .monotonic);
    }

    pub const Want = struct {
        slot: u10,
        local: u16,
        location: Location,
        output: []u8,
        value: []const u8 = &.{},
    };

    // Kept small: ReleaseSafe fills undefined stack arrays.
    const max_gap = 4096;
    const max_span = 256 * 1024;

    fn readWanted(self: *Store, generation: *Generation, wants: []Want, scratch: *Buffer) !void {
        const order = if (wants.len <= scratch.order.len) scratch.order[0..wants.len] else try self.allocator.alloc(u16, wants.len);
        defer if (wants.len > scratch.order.len) self.allocator.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.sort.insertion(u16, order, wants, wantLessThan);

        var first: usize = 0;
        while (first < wants.len) {
            const head = wants[order[first]].location;
            const start: u64 = head.offset;
            var end = start + head.recordLen();
            var last = first + 1;
            while (last < wants.len) : (last += 1) {
                const next = wants[order[last]].location;
                const next_end = next.offset + next.recordLen();
                if (next.segment != head.segment or next.offset > end + max_gap or next_end - start > max_span) break;
                end = @max(end, next_end);
            }
            try self.reserve(scratch, @intCast(end - start));
            const bytes = scratch.bytes[0..@intCast(end - start)];
            try generation.devices[head.segment].readExact(bytes, start);
            self.countRead(bytes.len);
            for (order[first..last]) |i| {
                const want = &wants[i];
                const at: usize = @intCast(want.location.offset - start);
                const decoded = try checkRecord(bytes[at..][0..want.location.recordLen()], want.location, want.slot, want.local);
                want.value = try decodeInto(decoded, want.output);
            }
            first = last;
        }
    }

    fn wantLessThan(wants: []const Want, a: u16, b: u16) bool {
        const x = wants[a].location;
        const y = wants[b].location;
        if (x.segment != y.segment) return x.segment < y.segment;
        return x.offset < y.offset;
    }

    pub fn getMany(self: *Store, requests: []const ReadRequest, results: []ReadResult) !void {
        std.debug.assert(requests.len == results.len);
        if (requests.len > max_batch_keys) return error.TooManyKeys;
        if (self.options.stats) |s| _ = s.get_calls.fetchAdd(requests.len, .monotonic);
        @memset(results, .{});
        for (requests) |request| {
            if (!request.key.region().eql(self.region)) return error.RegionMismatch;
            try request.key.validate();
        }
        var start: usize = 0;
        while (start < requests.len) : (start += read_chunk) {
            const end = @min(requests.len, start + read_chunk);
            try self.getChunkOfMany(requests[start..end], results[start..end]);
        }
    }

    const read_chunk = inline_records;

    fn getChunkOfMany(self: *Store, requests: []const ReadRequest, results: []ReadResult) !void {
        const scratch = try self.borrow(0);
        defer self.giveBack(scratch);
        const wants = &scratch.wants;
        const targets = &scratch.targets;
        var count: usize = 0;
        const generation = blk: {
            try self.table.lockShared(self.io);
            defer self.table.unlockShared(self.io);
            if (self.closing) return error.Closed;
            const generation = self.generation;
            for (requests, results, 0..) |request, *result, i| {
                const slot = request.key.slot();
                const local = request.key.local();
                const location = generation.index.lookup(slot, local) orelse continue;
                if (location.segment >= generation.count) return error.IndexMismatch;
                result.required = location.raw_len;
                if (request.output.len < location.raw_len) {
                    result.status = .buffer_too_small;
                    continue;
                }
                wants[count] = .{ .slot = slot, .local = local, .location = location, .output = request.output };
                targets[count] = @intCast(i);
                count += 1;
            }
            if (count == 0) return;
            _ = generation.readers.fetchAdd(1, .seq_cst);
            break :blk generation;
        };
        defer self.unpin(generation);

        var misses: usize = 0;
        for (wants[0..count], targets[0..count]) |want, target| {
            if (self.options.cache) |cache| if (cache.get(self.io, requests[target].key, want.location.batch_id, want.output)) |value| {
                results[target] = .{ .status = .ok, .required = value.len, .value = value };
                continue;
            };
            wants[misses] = want;
            targets[misses] = target;
            misses += 1;
        }
        try self.readWanted(generation, wants[0..misses], scratch);
        for (wants[0..misses], targets[0..misses]) |want, target| {
            if (self.options.cache) |cache| cache.put(self.io, requests[target].key, want.location.batch_id, want.value);
            results[target] = .{ .status = .ok, .required = want.value.len, .value = want.value };
        }
    }

    /// Values are packed into `buffer` in key order.
    /// BufferTooSmall fills `result` for a retry.
    pub fn getChunk(self: *Store, chunk_x: i32, chunk_z: i32, buffer: []u8, records: []ChunkRecord, result: *ChunkResult) !void {
        const probe: Key = .{ .dimension = self.region.dimension, .chunk_x = chunk_x, .chunk_z = chunk_z, .component = .version };
        if (!probe.region().eql(self.region)) return error.RegionMismatch;
        const scratch = try self.borrow(0);
        defer self.giveBack(scratch);
        var heap: ?[]align(@alignOf(Want)) u8 = null;
        defer if (heap) |bytes| self.allocator.free(bytes);
        var entries: []index_module.Entry = &scratch.entries;
        var wants: []Want = &scratch.wants;
        while (true) {
            const generation, const count = blk: {
                try self.table.lockShared(self.io);
                defer self.table.unlockShared(self.io);
                if (self.closing) return error.Closed;
                const generation = self.generation;
                const count = generation.index.chunkEntries(probe.slot(), entries);
                if (count > entries.len) break :blk .{ generation, count };
                for (entries[0..count]) |entry| if (entry.location.segment >= generation.count) return error.IndexMismatch;
                if (count != 0) _ = generation.readers.fetchAdd(1, .seq_cst);
                break :blk .{ generation, count };
            };
            if (count > entries.len) {
                // Rare: too many to fit on the stack.
                if (heap) |bytes| self.allocator.free(bytes);
                heap = null;
                const capacity = count + 16;
                const bytes = try self.allocator.alignedAlloc(u8, .of(Want), capacity * (@sizeOf(Want) + @sizeOf(index_module.Entry)));
                heap = bytes;
                wants = @as([*]Want, @ptrCast(bytes.ptr))[0..capacity];
                entries = @as([*]index_module.Entry, @ptrCast(@alignCast(bytes.ptr + capacity * @sizeOf(Want))))[0..capacity];
                continue;
            }
            if (count == 0) {
                result.* = .{ .count = 0, .required = 0 };
                return;
            }
            defer self.unpin(generation);
            return self.readChunk(generation, probe.slot(), entries[0..count], wants, scratch, buffer, records, result);
        }
    }

    pub const inline_records = 32;

    fn readChunk(self: *Store, generation: *Generation, slot: u10, entries: []const index_module.Entry, wants: []Want, scratch: *Buffer, buffer: []u8, records: []ChunkRecord, result: *ChunkResult) !void {
        if (self.options.stats) |s| _ = s.get_calls.fetchAdd(entries.len, .monotonic);
        var required: usize = 0;
        for (entries) |entry| required += entry.location.raw_len;
        result.* = .{ .count = entries.len, .required = required };
        if (buffer.len < required or records.len < entries.len) return error.BufferTooSmall;

        var used: usize = 0;
        var misses: usize = 0;
        for (entries, records[0..entries.len]) |entry, *out| {
            const output = buffer[used..][0..entry.location.raw_len];
            used += output.len;
            const key = Key.fromLocal(self.region, slot, entry.local);
            out.* = .{ .component = key.component, .subchunk_y = @intCast(key.subchunk_y), .value = output };
            if (self.options.cache) |cache| if (cache.get(self.io, key, entry.location.batch_id, output) != null) continue;
            wants[misses] = .{ .slot = slot, .local = entry.local, .location = entry.location, .output = output };
            misses += 1;
        }
        try self.readWanted(generation, wants[0..misses], scratch);
        if (self.options.cache) |cache| for (wants[0..misses]) |want| {
            cache.put(self.io, Key.fromLocal(self.region, slot, want.local), want.location.batch_id, want.value);
        };
    }

    pub fn keys(self: *Store, allocator: std.mem.Allocator, filter: KeyFilter) ![]Key {
        var list: std.ArrayListUnmanaged(Key) = .empty;
        errdefer list.deinit(allocator);
        {
            try self.table.lockShared(self.io);
            defer self.table.unlockShared(self.io);
            if (self.closing) return error.Closed;
            try self.generation.index.appendKeys(allocator, filter, &list);
        }
        const result = try list.toOwnedSlice(allocator);
        std.mem.sort(Key, result, {}, key_format.keyLessThan);
        return result;
    }

    pub fn lastBatchId(self: *Store) !u64 {
        try self.table.lockShared(self.io);
        defer self.table.unlockShared(self.io);
        if (self.closing) return error.Closed;
        return self.generation.index.lastBatchId();
    }

    pub fn valueSize(self: *Store, key: Key) !?u32 {
        try key.validate();
        try self.table.lockShared(self.io);
        defer self.table.unlockShared(self.io);
        if (self.closing) return error.Closed;
        const location = (try self.generation.index.get(key)) orelse return null;
        return location.raw_len;
    }

    /// Writers only wait for the final tail copy, its fsync and the manifest swap.
    pub fn compact(self: *Store) !CompactionResult {
        try lock.lock(&self.compact_mutex, self.io);
        defer self.compact_mutex.unlock(self.io);
        const started: ?std.Io.Clock.Timestamp = if (self.options.stats != null) std.Io.Clock.Timestamp.now(self.io, .awake) else null;

        // Close waits on compact_mutex, so `old` stays alive.
        var live: std.ArrayListUnmanaged(Live) = .empty;
        defer live.deinit(self.allocator);
        const old, const snapshot = try self.takeSnapshot(&live);
        const next_generation = std.math.add(u64, old.index.generation, 1) catch return error.GenerationExhausted;

        var index = try Index.init(self.allocator, self.region, next_generation, self.options.max_keys);
        var index_owned = true;
        defer if (index_owned) index.deinit();
        index.stats = self.options.stats;
        index.fingerprints = self.options.skip_unchanged;
        index.order = .{ .last_batch_id = snapshot.last_batch_id };

        const ids = try self.allocator.alloc(u64, self.options.max_segments);
        defer self.allocator.free(ids);
        const devices = try self.allocator.alloc(File, self.options.max_segments);
        defer self.allocator.free(devices);
        const old_ids = try self.allocator.alloc(u64, self.options.max_segments);
        defer self.allocator.free(old_ids);
        var output: CompactionOutput = .{
            .io = self.io,
            .dir = self.directory.dir,
            .generation = next_generation,
            .region = self.region,
            .salt = self.salt,
            .max_size = self.options.max_segment_size,
            .ids = ids,
            .devices = devices,
        };
        var published = false;
        defer if (!published) output.discard();

        var scratch = try self.allocator.alloc(u8, self.options.batch_buffer_size);
        defer self.allocator.free(scratch);
        var staging = try self.allocator.alloc(u8, self.options.batch_buffer_size);
        defer self.allocator.free(staging);
        var source_bytes: u64 = 0;
        self.writeBase(old, live.items, &output, &index, snapshot.last_batch_id, &scratch, &staging, &source_bytes) catch |err|
            return if (isSourceError(err)) self.sourceFailure(err, false) else err;
        try output.sync();

        var tail: Tail = .{ .position = snapshot.position, .offset = snapshot.offset };
        for (0..4) |_| {
            const copied = try self.copyTail(old, &tail, &output, &index, &scratch, false);
            source_bytes += copied;
            if (copied <= catch_up_bytes) break;
        }

        const old_count, const output_count = blk: {
            try lock.lock(&self.writer, self.io);
            defer self.writer.unlock(self.io);
            if (self.closed) return error.Closed;
            if (self.failed) return error.WriterFailed;
            source_bytes += try self.copyTail(old, &tail, &output, &index, &scratch, true);
            try output.sync();

            var buffer: [manifest.max_encoded_len]u8 = undefined;
            const bytes = try self.manifestBytes(&buffer, next_generation, ids[0..output.count], snapshot.last_batch_id);
            const fresh = try newGeneration(self.allocator, self.io, self.options.max_segments);
            fresh.index = index;
            index_owned = false;
            @memcpy(fresh.devices[0..output.count], devices[0..output.count]);
            @memcpy(fresh.segment_ids[0..output.count], ids[0..output.count]);
            // The manifest may name the new files once publishing starts, so keep them.
            published = true;
            {
                lock.lockUncancelable(&self.directory_mutex, self.io);
                defer self.directory_mutex.unlock(self.io);
                var publisher: publication.Publisher(*Directory) = .{ .backend = &self.directory };
                publisher.publish(bytes) catch |err| {
                    self.failed = true;
                    output.deinit();
                    fresh.destroy();
                    return err;
                };
            }
            fresh.count = output.count;
            output.count = 0;
            @memcpy(old_ids[0..old.count], old.segment_ids[0..old.count]);
            {
                self.table.lockUncancelable(self.io);
                defer self.table.unlock(self.io);
                self.generation = fresh;
            }
            self.base_batch_id = snapshot.last_batch_id;
            self.segment_id = ids[fresh.count - 1];
            self.offset = output.offset;
            self.synced_offset = output.offset;
            self.epoch += 1;
            break :blk .{ old.count, fresh.count };
        };

        const output_bytes = output.bytes;
        const old_generation = old.index.generation;
        self.waitReaders(old);
        old.destroy();
        const cleanup = blk: {
            lock.lockUncancelable(&self.directory_mutex, self.io);
            defer self.directory_mutex.unlock(self.io);
            break :blk reclamation.reclaim(&self.directory, next_generation, old_generation, old_ids[0..old_count]);
        };
        if (self.options.stats) |s| {
            _ = s.compactions.fetchAdd(1, .monotonic);
            // One per new segment plus the manifest file and two directory syncs.
            _ = s.fsync_count.fetchAdd(output_count + 3, .monotonic);
            _ = s.compaction_input_bytes.fetchAdd(source_bytes, .monotonic);
            _ = s.compaction_output_bytes.fetchAdd(output_bytes, .monotonic);
            if (started) |t| _ = s.compaction_duration_ns.fetchAdd(@intCast(t.untilNow(self.io).raw.nanoseconds), .monotonic);
        }
        return .{
            .generation = next_generation,
            .segment_count = output_count,
            .source_bytes = source_bytes,
            .output_bytes = output_bytes,
            .cleanup = cleanup,
        };
    }

    const catch_up_bytes = 256 * 1024;

    const Snapshot = struct {
        position: usize,
        offset: u64,
        last_batch_id: u64,
    };

    const Live = struct {
        slot: u10,
        local: u16,
        location: Location,
    };

    fn takeSnapshot(self: *Store, live: *std.ArrayListUnmanaged(Live)) !struct { *Generation, Snapshot } {
        try lock.lock(&self.writer, self.io);
        defer self.writer.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.failed) return error.WriterFailed;
        // Only appends change the index, under the writer lock.
        const generation = self.generation;
        try live.ensureTotalCapacity(self.allocator, generation.index.count);
        const Collect = struct {
            fn visit(list: *std.ArrayListUnmanaged(Live), slot: u10, local: u16, location: Location) !void {
                list.appendAssumeCapacity(.{ .slot = slot, .local = local, .location = location });
            }
        };
        try generation.index.each(live, Collect.visit);
        return .{ generation, .{
            .position = generation.count - 1,
            .offset = self.offset,
            .last_batch_id = generation.index.lastBatchId(),
        } };
    }

    fn isSourceError(err: anyerror) bool {
        return switch (err) {
            error.OutOfMemory, error.Canceled, error.TooManySegments, error.NoSpaceLeft, error.DiskQuota => false,
            else => true,
        };
    }

    fn writeBase(self: *Store, old: *Generation, live: []const Live, output: *CompactionOutput, index: *Index, base_id: u64, scratch: *[]u8, staging: *[]u8, source_bytes: *u64) !void {
        var reads: std.ArrayListUnmanaged(u32) = .empty;
        defer reads.deinit(self.allocator);
        const places = try self.allocator.alloc(usize, frame.max_records);
        defer self.allocator.free(places);

        var first: usize = 0;
        while (first < live.len) {
            const largest = frame.header_len + live[first].location.recordLen();
            if (largest > staging.len) staging.* = try self.allocator.realloc(staging.*, largest);
            if (largest > scratch.len) scratch.* = try self.allocator.realloc(scratch.*, largest);
            var last = first;
            var size: usize = frame.header_len;
            while (last < live.len and last - first < frame.max_records) : (last += 1) {
                const len = live[last].location.recordLen();
                if (size + len > staging.len) break;
                places[last - first] = size;
                size += len;
            }
            const window = live[first..last];
            var builder = frame.Builder.init(staging.*);

            // Read in file order, then place each record in chunk order.
            reads.clearRetainingCapacity();
            for (0..window.len) |i| try reads.append(self.allocator, @intCast(i));
            std.mem.sort(u32, reads.items, window, liveLessThan);
            var i: usize = 0;
            while (i < reads.items.len) {
                const head = window[reads.items[i]].location;
                var end: u64 = @as(u64, head.offset) + head.recordLen();
                var j = i + 1;
                while (j < reads.items.len) : (j += 1) {
                    const next = window[reads.items[j]].location;
                    const next_end = @as(u64, next.offset) + next.recordLen();
                    if (next.segment != head.segment or next.offset > end + 64 * 1024 or next_end - head.offset > scratch.len) break;
                    end = @max(end, next_end);
                }
                const bytes = scratch.*[0..@intCast(end - head.offset)];
                try old.devices[head.segment].readExact(bytes, head.offset);
                source_bytes.* += bytes.len;
                for (reads.items[i..j]) |w| {
                    const item = window[w];
                    const from: usize = @intCast(item.location.offset - head.offset);
                    const record_bytes = bytes[from..][0..item.location.recordLen()];
                    _ = try checkRecord(record_bytes, item.location, item.slot, item.local);
                    @memcpy(staging.*[places[w]..][0..record_bytes.len], record_bytes);
                }
                i = j;
            }

            for (window) |item| {
                const len = item.location.recordLen();
                builder.checksums = crc.update(builder.checksums, staging.*[builder.len + len - 4 ..][0..4]);
                builder.len += len;
                builder.count += 1;
            }
            const bytes = builder.finish(.base, base_id, self.salt);
            const placed = try output.append(bytes);
            const batch: scan.Batch = .{ .header = builder.header(.base, base_id), .bytes = bytes, .offset = placed.offset };
            try index.apply(batch, placed.position);
            first = last;
        }
    }

    fn liveLessThan(live: []const Live, a: u32, b: u32) bool {
        const x = live[a].location;
        const y = live[b].location;
        if (x.segment != y.segment) return x.segment < y.segment;
        return x.offset < y.offset;
    }

    const Tail = struct {
        position: usize,
        offset: u64,
    };

    /// `locked` means the writer lock is held.
    fn copyTail(self: *Store, old: *Generation, tail: *Tail, output: *CompactionOutput, index: *Index, scratch: *[]u8, locked: bool) !u64 {
        const end_position, const end_offset = if (locked) .{ old.count - 1, self.offset } else blk: {
            try lock.lock(&self.writer, self.io);
            defer self.writer.unlock(self.io);
            break :blk .{ old.count - 1, self.offset };
        };
        var copied: u64 = 0;
        while (true) {
            const last = tail.position == end_position;
            const device = old.devices[tail.position];
            var scanner = Scanner.init(device, .{
                .segment_id = old.segment_ids[tail.position],
                .generation = old.index.generation,
                .region = self.region,
                .salt = self.salt,
            }, .sealed, index.order, std.math.maxInt(u64)) catch |err| return self.sourceFailure(err, locked);
            if (last) scanner.length = end_offset;
            scanner.seek(tail.offset) catch |err| return self.sourceFailure(err, locked);
            while (scanner.nextGrowing(self.allocator, scratch) catch |err| return self.sourceFailure(err, locked)) |batch| {
                const placed = try output.append(batch.bytes);
                var moved = batch;
                moved.offset = placed.offset;
                try index.apply(moved, placed.position);
                copied += batch.bytes.len;
            }
            tail.offset = scanner.offset;
            if (last) return copied;
            tail.position += 1;
            tail.offset = segment.encoded_len;
        }
    }

    pub fn reclaim(self: *Store, generation: u64, ids: []const u64) !reclamation.Result {
        try lock.lock(&self.writer, self.io);
        defer self.writer.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.failed) return error.WriterFailed;
        lock.lockUncancelable(&self.directory_mutex, self.io);
        defer self.directory_mutex.unlock(self.io);
        return reclamation.reclaim(&self.directory, self.generation.index.generation, generation, ids);
    }

    fn sourceFailure(self: *Store, err: anyerror, locked: bool) anyerror {
        if (err != error.Canceled) {
            if (!locked) lock.lockUncancelable(&self.writer, self.io);
            defer if (!locked) self.writer.unlock(self.io);
            self.failed = true;
        }
        return err;
    }

    pub fn close(self: *Store) !void {
        lock.lockUncancelable(&self.compact_mutex, self.io);
        defer self.compact_mutex.unlock(self.io);
        if (self.closed) return;
        const barrier = self.commitBarrier();
        if (barrier) |_| {
            lock.lockUncancelable(&self.writer, self.io);
            defer self.writer.unlock(self.io);
            if (!self.failed) self.writeCheckpoint();
        } else |_| {}
        self.release();
        try barrier;
    }

    pub fn deinit(self: *Store) void {
        lock.lockUncancelable(&self.compact_mutex, self.io);
        defer self.compact_mutex.unlock(self.io);
        if (!self.closed) self.release();
    }

    fn release(self: *Store) void {
        {
            lock.lockUncancelable(&self.writer, self.io);
            defer self.writer.unlock(self.io);
            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            self.closing = true;
            self.closed = true;
        }
        self.waitReaders(self.generation);
        self.generation.destroy();
        for (self.pool.items) |buffer| {
            self.allocator.free(buffer.bytes);
            self.allocator.destroy(buffer);
        }
        self.pool.deinit(self.allocator);
        self.directory.deinit();
    }
};
