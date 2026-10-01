const std = @import("std");

const lock = @import("../lock.zig");

const commit = @import("../batch/commit.zig");
const WriteBatch = @import("../batch/write.zig").WriteBatch;
const entry = @import("../format/entry.zig");
const key_format = @import("../format/key.zig");
const Key = key_format.Key;
const KeyFilter = key_format.KeyFilter;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const index_module = @import("../index/index.zig");
const writer_module = @import("../storage/writer.zig");
const Stats = @import("../stats.zig").Stats;
const Cache = @import("../cache/value.zig").Cache;

pub const Options = struct {
    max_keys: u32 = 65536,
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    batch_buffer_size: usize = 1024 * 1024,
    durability: writer_module.Durability = .buffered,
    stats: ?*Stats = null,
    cache: ?*Cache = null,
    skip_unchanged: bool = false,
    // Ask for compaction once live data drops below this share of a store this big.
    compact_min_bytes: u64 = 16 * 1024 * 1024,
    compact_live_percent: u8 = 50,

    pub fn validate(self: Options) !void {
        if (self.max_segments == 0 or self.max_segments > manifest.max_segments) return error.InvalidSegmentCount;

        if (self.batch_buffer_size < entry.overhead + commit.commit_len or
            self.batch_buffer_size > commit.max_bytes + commit.commit_len)
            return error.InvalidBufferSize;

        if (self.max_segment_size < segment.encoded_len) return error.SegmentFull;
    }
};

pub fn Shard(comptime Device: type) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        writer: writer_module.Writer(Device),
        generation: *Generation,
        options: Options,
        scratch: []u8,
        // Serializes writers and guards `idle`.
        mutex: std.Io.Mutex = .init,
        // Shared for readers; exclusive to change the generation, index or close state.
        table: std.Io.RwLock = .init,
        idle: std.Io.Condition = .init,
        drainers: std.atomic.Value(usize) = .init(0),
        closed: bool = false,
        closing: bool = false,
        spare_mutex: std.Io.Mutex = .init,
        spare: std.ArrayListUnmanaged([]u8) = .empty,
        lent: usize = 0,

        const Self = @This();

        pub const Generation = struct {
            allocator: std.mem.Allocator,
            index: index_module.Index,
            devices: []Device,
            segment_ids: []u64,
            segment_count: usize,
            readers: std.atomic.Value(usize) = .init(0),

            pub fn destroy(self: *Generation) void {
                self.index.deinit();
                self.allocator.free(self.devices);
                self.allocator.free(self.segment_ids);
                self.allocator.destroy(self);
            }
        };

        const Pinned = struct {
            generation: *Generation,
            device: Device,
            location: index_module.Location,
            scratch: ?[]u8 = null,
        };

        pub const max_batch_keys = 128;

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

        const BatchSlot = struct {
            segment_position: u16,
            location: index_module.Location,
        };

        pub fn create(allocator: std.mem.Allocator, io: std.Io, device: Device, header: segment.Header, options: Options) !Self {
            try options.validate();

            const scratch = try allocator.alloc(u8, options.batch_buffer_size + segment.encoded_len);
            errdefer allocator.free(scratch);

            const devices = try allocator.alloc(Device, options.max_segments);
            errdefer allocator.free(devices);
            const ids = try allocator.alloc(u64, options.max_segments);
            errdefer allocator.free(ids);

            devices[0] = device;
            ids[0] = header.segment_id;

            const generation = try allocator.create(Generation);
            errdefer allocator.destroy(generation);
            generation.* = .{
                .allocator = allocator,
                .index = .{
                    .allocator = allocator,
                    .region = header.region,
                    .generation = header.generation,
                    .max_keys = options.max_keys,
                    .stats = options.stats,
                    .segment_ids = ids,
                    .fingerprints = options.skip_unchanged,
                },
                .devices = devices,
                .segment_ids = ids,
                .segment_count = 1,
            };

            var writer = try writer_module.Writer(Device).create(device, header, options.max_segment_size, 0);
            writer.stats = options.stats;
            writer.io = io;

            return .{
                .allocator = allocator,
                .io = io,
                .writer = writer,
                .generation = generation,
                .options = options,
                .scratch = scratch,
            };
        }

        pub fn open(allocator: std.mem.Allocator, io: std.Io, device: Device, header: segment.Header, options: Options) !Self {
            return openSegments(allocator, io, &.{device}, .{
                .generation = header.generation,
                .region = header.region,
                .segments = &.{header.segment_id},
            }, options);
        }

        pub fn openSegments(
            allocator: std.mem.Allocator,
            io: std.Io,
            source_devices: []const Device,
            metadata: manifest.Manifest,
            options: Options,
        ) !Self {
            try options.validate();
            if (source_devices.len == 0 or source_devices.len > options.max_segments or
                source_devices.len != metadata.segments.len)
                return error.InvalidSegmentCount;

            const scratch = try allocator.alloc(u8, options.batch_buffer_size + segment.encoded_len);
            errdefer allocator.free(scratch);
            const devices = try allocator.alloc(Device, options.max_segments);
            errdefer allocator.free(devices);
            const ids = try allocator.alloc(u64, options.max_segments);
            errdefer allocator.free(ids);

            @memcpy(devices[0..source_devices.len], source_devices);
            @memcpy(ids[0..source_devices.len], metadata.segments);

            var index = try index_module.rebuildFiles(
                allocator,
                metadata,
                source_devices,
                options.max_keys,
                scratch,
                options.max_segment_size,
                options.skip_unchanged,
            );
            errdefer index.deinit();
            index.stats = options.stats;
            index.segment_ids = ids;

            if (index.has_tail) return error.NeedsRecovery;

            const active = source_devices.len - 1;
            const device = devices[active];
            if (try device.length() != index.active_offset) return error.FileChanged;

            try device.sync();

            const generation = try allocator.create(Generation);
            errdefer allocator.destroy(generation);
            generation.* = .{
                .allocator = allocator,
                .index = index,
                .devices = devices,
                .segment_ids = ids,
                .segment_count = source_devices.len,
            };

            return .{
                .allocator = allocator,
                .io = io,
                .writer = .{
                    .device = device,
                    .header = .{
                        .segment_id = ids[active],
                        .generation = metadata.generation,
                        .region = metadata.region,
                    },
                    .max_size = options.max_segment_size,
                    .offset = index.active_offset,
                    .synced_offset = index.active_offset,
                    .last_batch_id = index.last_batch_id,
                    .stats = options.stats,
                    .io = io,
                },
                .generation = generation,
                .options = options,
                .scratch = scratch,
            };
        }

        pub fn rotate(self: *Self, device: Device, id: u64, publisher: anytype) !void {
            try lock.lock(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;
            if (self.writer.failed) return error.WriterFailed;
            if (self.generation.segment_count == self.options.max_segments) return error.TooManySegments;
            if (id <= self.writer.header.segment_id) return error.InvalidSegmentOrder;
            if (try device.length() != 0) return error.FileNotEmpty;

            const count = self.generation.segment_count + 1;
            const buffer = try self.allocator.alloc(u8, manifest.header_len + count * 8 + 4);
            defer self.allocator.free(buffer);

            self.generation.segment_ids[self.generation.segment_count] = id;
            const bytes = try (manifest.Manifest{
                .generation = self.generation.index.generation,
                .region = self.generation.index.region,
                .segments = self.generation.segment_ids[0..count],
            }).encode(buffer);

            try self.writer.flush();

            var next = try writer_module.Writer(Device).create(device, .{
                .segment_id = id,
                .generation = self.generation.index.generation,
                .region = self.generation.index.region,
            }, self.options.max_segment_size, self.writer.last_batch_id);
            next.stats = self.options.stats;
            next.io = self.io;

            publisher.publish(bytes) catch |err| {
                self.writer.failed = true;
                return err;
            };

            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            self.generation.devices[self.generation.segment_count] = device;
            self.generation.segment_count = count;
            self.writer = next;
            self.generation.index.active_offset = segment.encoded_len;
        }

        pub fn write(self: *Self, batch: WriteBatch) !writer_module.AppendResult {
            return (try self.writeBatches(&.{batch}, false)).result;
        }

        pub const Written = struct {
            result: writer_module.AppendResult,
            count: usize,
        };

        /// Writes as many leading batches as fit in one append.
        pub fn writeBatches(self: *Self, batches: []const WriteBatch, validated: bool) !Written {
            try lock.lock(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;
            if (self.writer.failed) return error.WriterFailed;

            const buffer = self.scratch[0..self.options.batch_buffer_size];
            const room = self.options.max_segment_size - self.writer.offset;
            var used: usize = 0;
            var count: usize = 0;
            for (batches) |batch| {
                const len = try if (validated) batch.size() else batch.validate();
                if (len > buffer.len - used) {
                    if (count == 0) return error.BufferTooSmall;
                    break;
                }
                if (used + len > room) {
                    if (count == 0) return error.SegmentFull;
                    break;
                }
                _ = try batch.encodeChecked(buffer[used..]);
                used += len;
                count += 1;
            }

            const prepared = blk: {
                self.table.lockUncancelable(self.io);
                defer self.table.unlock(self.io);
                break :blk try self.generation.index.prepareBatches(batches[0..count], self.writer.offset, self.generation.segment_count - 1);
            };
            const result = try self.writer.appendTrusted(buffer[0..used], batches[count - 1].id(), self.options.durability);
            {
                self.table.lockUncancelable(self.io);
                defer self.table.unlock(self.io);
                self.generation.index.publish(prepared);
            }
            self.generation.index.active_offset = @intCast(result.end);
            return .{ .result = result, .count = count };
        }

        fn pin(self: *Self, key: Key) !?Pinned {
            try self.table.lockShared(self.io);
            defer self.table.unlockShared(self.io);

            if (self.closed or self.closing) return error.Closed;

            const generation = self.generation;
            const location = (try generation.index.get(key)) orelse return null;
            if (location.segment >= generation.segment_count) return error.IndexMismatch;

            _ = generation.readers.fetchAdd(1, .seq_cst);
            return .{
                .generation = generation,
                .device = generation.devices[location.segment],
                .location = location,
            };
        }

        fn unpin(self: *Self, generation: *Generation, scratch: ?[]u8) void {
            if (scratch) |buffer| self.giveBack(buffer);
            if (generation.readers.fetchSub(1, .seq_cst) != 1 or self.drainers.load(.seq_cst) == 0) return;
            lock.lockUncancelable(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);
            self.idle.broadcast(self.io);
        }

        /// Waits for every reader of `generation`; `mutex` must be held.
        fn waitReaders(self: *Self, generation: *Generation) void {
            _ = self.drainers.fetchAdd(1, .seq_cst);
            defer _ = self.drainers.fetchSub(1, .seq_cst);
            while (generation.readers.load(.seq_cst) != 0) self.idle.waitUncancelable(self.io, &self.mutex);
        }

        const min_spare_len = 64 * 1024;
        const max_spare_len = 1024 * 1024;

        /// Reserves room in the pool so `giveBack` never allocates.
        fn borrow(self: *Self, scratch: *?[]u8, len: usize) ![]u8 {
            if (scratch.* == null) {
                lock.lockUncancelable(&self.spare_mutex, self.io);
                defer self.spare_mutex.unlock(self.io);
                try self.spare.ensureTotalCapacity(self.allocator, self.spare.items.len + self.lent + 1);
                self.lent += 1;
                scratch.* = self.spare.pop() orelse &.{};
            }
            if (scratch.*.?.len < len) {
                self.allocator.free(scratch.*.?);
                scratch.* = &.{};
                scratch.* = try self.allocator.alloc(u8, @max(len, min_spare_len));
            }
            return scratch.*.?[0..len];
        }

        fn giveBack(self: *Self, buffer: []u8) void {
            lock.lockUncancelable(&self.spare_mutex, self.io);
            defer self.spare_mutex.unlock(self.io);
            self.lent -= 1;
            if (buffer.len == 0) return;
            if (buffer.len > max_spare_len) return self.allocator.free(buffer);
            self.spare.appendAssumeCapacity(buffer);
        }

        fn pinMany(self: *Self, requests: []const ReadRequest, slots: []?BatchSlot) !?*Generation {
            try self.table.lockShared(self.io);
            defer self.table.unlockShared(self.io);

            if (self.closed or self.closing) return error.Closed;

            const generation = self.generation;
            var hits: usize = 0;
            for (requests, slots) |request, *slot| {
                const location = (try generation.index.get(request.key)) orelse {
                    slot.* = null;
                    continue;
                };
                if (location.segment >= generation.segment_count) return error.IndexMismatch;
                slot.* = .{ .segment_position = location.segment, .location = location };
                hits += 1;
            }

            if (hits == 0) return null;
            _ = generation.readers.fetchAdd(1, .seq_cst);
            return generation;
        }

        fn readPinned(self: *Self, pinned: *Pinned, key: Key, output: []u8) !?[]const u8 {
            const batch_id = pinned.location.batch_id;
            if (self.options.cache) |cache| if (cache.get(self.io, key, batch_id, output)) |value| return value;

            const scratch = try self.borrow(&pinned.scratch, recordLen(pinned.location));
            const value = try pinned.generation.index.readAtInto(pinned.location, key, pinned.device, scratch, output);
            if (self.options.cache) |cache| cache.put(self.io, key, batch_id, value);
            return value;
        }

        pub fn unchanged(self: *Self, item: entry.Entry) !bool {
            var pinned = (try self.pin(item.key)) orelse return item.header.kind == .delete;
            defer self.unpin(pinned.generation, pinned.scratch);
            if (item.header.kind == .delete) return false;

            const location = pinned.location;
            if (location.stored_len != item.header.stored_len or location.raw_len != item.header.raw_len or
                location.fingerprint != index_module.fingerprint(item.header.compression, item.value)) return false;

            const scratch = try self.borrow(&pinned.scratch, recordLen(location));
            const stored = try pinned.generation.index.readRecordAt(location, item.key, pinned.device, scratch);
            return stored.header.compression == item.header.compression and std.mem.eql(u8, stored.value, item.value);
        }

        pub fn keys(self: *Self, allocator: std.mem.Allocator, filter: KeyFilter) ![]Key {
            var list: std.ArrayListUnmanaged(Key) = .empty;
            errdefer list.deinit(allocator);
            {
                try self.table.lockShared(self.io);
                defer self.table.unlockShared(self.io);
                if (self.closed or self.closing) return error.Closed;
                try self.generation.index.appendKeys(allocator, filter, &list);
            }
            const result = try list.toOwnedSlice(allocator);
            std.mem.sort(Key, result, {}, key_format.keyLessThan);
            return result;
        }

        pub fn get(self: *Self, key: Key, output: []u8) !?[]const u8 {
            var pinned = (try self.pin(key)) orelse return null;
            defer self.unpin(pinned.generation, pinned.scratch);

            return self.readPinned(&pinned, key, output);
        }

        pub fn getSized(self: *Self, key: Key, output: []u8, required: *usize) !?[]const u8 {
            var pinned = (try self.pin(key)) orelse return null;
            defer self.unpin(pinned.generation, pinned.scratch);

            required.* = pinned.location.raw_len;
            if (output.len < pinned.location.raw_len) return error.BufferTooSmall;

            return self.readPinned(&pinned, key, output);
        }

        // Kept small: ReleaseSafe fills undefined stack arrays.
        const read_chunk = 32;
        const max_gap = 4096;
        const max_span = 256 * 1024;

        pub fn getMany(self: *Self, requests: []const ReadRequest, results: []ReadResult) !void {
            std.debug.assert(requests.len == results.len);
            if (requests.len > max_batch_keys) return error.TooManyKeys;
            var start: usize = 0;
            while (start < requests.len) : (start += read_chunk) {
                const end = @min(requests.len, start + read_chunk);
                try self.getChunk(requests[start..end], results[start..end]);
            }
        }

        fn getChunk(self: *Self, requests: []const ReadRequest, results: []ReadResult) !void {
            @memset(results, .{});
            const n = requests.len;

            var slots: [read_chunk]?BatchSlot = undefined;
            var scratch: ?[]u8 = null;
            const generation = (try self.pinMany(requests, slots[0..n])) orelse return;
            defer self.unpin(generation, scratch);

            for (requests, slots[0..n], results) |request, *slot, *result| {
                const location = (slot.* orelse continue).location;
                if (request.output.len < location.raw_len) {
                    result.* = .{ .status = .buffer_too_small, .required = location.raw_len };
                    slot.* = null;
                    continue;
                }
                if (self.options.cache) |cache| if (cache.get(self.io, request.key, location.batch_id, request.output)) |value| {
                    result.* = .{ .status = .ok, .required = value.len, .value = value };
                    slot.* = null;
                };
            }

            var order: [read_chunk]u8 = undefined;
            for (0..n) |i| order[i] = @intCast(i);
            sortByLocation(order[0..n], slots[0..n]);

            // Nearby records are read with one call and decoded from the same buffer.
            var first: usize = 0;
            while (first < n) {
                const head = slots[order[first]] orelse break;
                const start = head.location.offset;
                var end = start + recordLen(head.location);
                var last = first + 1;
                while (last < n) : (last += 1) {
                    const next = slots[order[last]] orelse break;
                    const next_end = next.location.offset + recordLen(next.location);
                    if (next.segment_position != head.segment_position or next.location.offset > end + max_gap or
                        next_end - start > max_span) break;
                    end = @max(end, next_end);
                }

                const bytes = try self.borrow(&scratch, @intCast(end - start));
                try generation.devices[head.segment_position].readExact(bytes, start);
                if (generation.index.stats) |s| {
                    _ = s.disk_reads.fetchAdd(1, .monotonic);
                    _ = s.bytes_read.fetchAdd(bytes.len, .monotonic);
                }

                for (order[first..last]) |i| {
                    const location = slots[i].?.location;
                    const record = bytes[@intCast(location.offset - start)..][0..recordLen(location)];
                    const value = try index_module.Index.decodeAt(record, location, requests[i].key, requests[i].output);
                    if (self.options.cache) |cache| cache.put(self.io, requests[i].key, location.batch_id, value);
                    results[i] = .{ .status = .ok, .required = value.len, .value = value };
                }
                first = last;
            }
        }

        fn recordLen(location: index_module.Location) usize {
            return @as(usize, location.stored_len) + entry.overhead;
        }

        fn sortByLocation(order: []u8, slots: []const ?BatchSlot) void {
            var i: usize = 1;
            while (i < order.len) : (i += 1) {
                const key = order[i];
                var j = i;
                while (j > 0 and locationLessThan(slots, key, order[j - 1])) : (j -= 1) order[j] = order[j - 1];
                order[j] = key;
            }
        }

        fn locationLessThan(slots: []const ?BatchSlot, a_idx: u8, b_idx: u8) bool {
            const a = slots[a_idx] orelse return false;
            const b = slots[b_idx] orelse return true;
            if (a.location.segment != b.location.segment) return a.location.segment < b.location.segment;
            return a.location.offset < b.location.offset;
        }

        pub fn swap(self: *Self, generation: *Generation, next_writer: writer_module.Writer(Device)) *Generation {
            lock.lockUncancelable(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);

            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            const old = self.generation;
            self.generation = generation;
            self.writer = next_writer;
            return old;
        }

        pub fn drain(self: *Self, generation: *Generation) void {
            lock.lockUncancelable(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);
            self.waitReaders(generation);
        }

        pub fn flush(self: *Self) !void {
            try lock.lock(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;

            try self.writer.flush();
        }

        pub fn syncAppended(self: *Self) !void {
            const device, const header, const offset = blk: {
                try lock.lock(&self.mutex, self.io);
                defer self.mutex.unlock(self.io);
                if (self.closed) return error.Closed;
                if (self.writer.failed) return error.WriterFailed;
                if (self.writer.synced_offset == self.writer.offset) return;
                break :blk .{ self.writer.device, self.writer.header, self.writer.offset };
            };

            const started: ?std.Io.Clock.Timestamp = if (self.options.stats != null) std.Io.Clock.Timestamp.now(self.io, .awake) else null;
            const result = device.sync();
            if (self.options.stats) |s| {
                _ = s.fsync_count.fetchAdd(1, .monotonic);
                if (started) |t| _ = s.fsync_duration_ns.fetchAdd(@intCast(t.untilNow(self.io).raw.nanoseconds), .monotonic);
            }

            lock.lockUncancelable(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);
            result catch |err| {
                self.writer.failed = true;
                return err;
            };
            const same = self.writer.header.segment_id == header.segment_id and self.writer.header.generation == header.generation;
            if (same and offset > self.writer.synced_offset) self.writer.synced_offset = offset;
        }

        pub fn close(self: *Self) !void {
            lock.lockUncancelable(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return;

            self.setClosing();
            const result = self.writer.flush();
            self.release();
            try result;
        }

        pub fn deinit(self: *Self) void {
            lock.lockUncancelable(&self.mutex, self.io);
            defer self.mutex.unlock(self.io);

            if (!self.closed) {
                self.setClosing();
                self.release();
            }
        }

        fn setClosing(self: *Self) void {
            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            self.closing = true;
        }

        fn release(self: *Self) void {
            self.waitReaders(self.generation);
            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            self.generation.destroy();
            self.allocator.free(self.scratch);
            for (self.spare.items) |buffer| self.allocator.free(buffer);
            self.spare.deinit(self.allocator);
            self.closed = true;
        }
    };
}
