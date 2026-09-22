const std = @import("std");

const commit = @import("../batch/commit.zig");
const WriteBatch = @import("../batch/write.zig").WriteBatch;
const entry = @import("../format/entry.zig");
const Key = @import("../format/key.zig").Key;
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
    durability: writer_module.Durability = .sync,
    stats: ?*Stats = null,
    cache: ?*Cache = null,

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
        mutex: std.Io.Mutex = .init,
        idle: std.Io.Condition = .init,
        closed: bool = false,
        closing: bool = false,

        const Self = @This();

        /// Generation state kept alive while reads are pinned.
        pub const Generation = struct {
            allocator: std.mem.Allocator,
            index: index_module.Index,
            devices: []Device,
            segment_ids: []u64,
            segment_count: usize,
            readers: usize = 0,

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
            );
            errdefer index.deinit();
            index.stats = options.stats;

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
            try self.mutex.lock(self.io);
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

            self.generation.devices[self.generation.segment_count] = device;
            self.generation.segment_count = count;
            self.writer = next;
            self.generation.index.active_offset = segment.encoded_len;
        }
        pub fn write(self: *Self, batch: WriteBatch) !writer_module.AppendResult {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;
            if (self.writer.failed) return error.WriterFailed;

            const bytes = try batch.encode(self.scratch[0..self.options.batch_buffer_size]);
            const end = std.math.add(u64, self.writer.offset, bytes.len) catch return error.SegmentFull;
            if (end > self.options.max_segment_size) return error.SegmentFull;

            var prepared = try self.generation.index.prepare(.{
                .id = batch.entries[0].header.batch_id,
                .records = bytes[0 .. bytes.len - commit.commit_len],
                .end_offset = std.math.cast(usize, end) orelse return error.InvalidLength,
            }, self.writer.header.segment_id);
            defer prepared.deinit();

            const result = try self.writer.appendEncoded(bytes, self.options.durability);
            self.generation.index.publish(&prepared);
            self.generation.index.active_offset = @intCast(result.end);

            return result;
        }

        /// Resolves and pins a generation.
        fn pin(self: *Self, key: Key) !?Pinned {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed or self.closing) return error.Closed;

            const generation = self.generation;
            const location = (try generation.index.get(key)) orelse return null;

            for (generation.segment_ids[0..generation.segment_count], generation.devices[0..generation.segment_count]) |id, device| {
                if (id != location.segment_id) continue;
                generation.readers += 1;
                return .{ .generation = generation, .device = device, .location = location };
            }

            return error.IndexMismatch;
        }

        fn unpin(self: *Self, generation: *Generation) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            generation.readers -= 1;
            if (generation.readers == 0) self.idle.broadcast(self.io);
        }

        fn pinMany(self: *Self, requests: []const ReadRequest, slots: []?BatchSlot) !?*Generation {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed or self.closing) return error.Closed;

            const generation = self.generation;
            var hits: usize = 0;
            for (requests, slots) |request, *slot| {
                const location = (try generation.index.get(request.key)) orelse {
                    slot.* = null;
                    continue;
                };
                var position: ?u16 = null;
                for (generation.segment_ids[0..generation.segment_count], 0..) |id, i| {
                    if (id == location.segment_id) {
                        position = @intCast(i);
                        break;
                    }
                }
                slot.* = .{ .segment_position = position orelse return error.IndexMismatch, .location = location };
                hits += 1;
            }

            if (hits == 0) return null;
            generation.readers += 1;
            return generation;
        }

        /// Uses stack scratch for small records.
        const inline_scratch_len = 8192;

        fn readPinned(self: *Self, pinned: Pinned, key: Key, output: []u8) !?[]const u8 {
            const batch_id = pinned.location.batch_id;
            if (self.options.cache) |cache| if (cache.get(self.io, key, batch_id, output)) |value| return value;

            const len = std.math.add(usize, entry.overhead, pinned.location.stored_len) catch return error.InvalidLength;
            var stack_scratch: [inline_scratch_len]u8 = undefined;
            const scratch = if (len <= stack_scratch.len) stack_scratch[0..len] else try self.allocator.alloc(u8, len);
            defer if (len > stack_scratch.len) self.allocator.free(scratch);

            const value = (try pinned.generation.index.readInto(key, pinned.device, scratch, output)) orelse return null;
            if (self.options.cache) |cache| cache.put(self.io, key, batch_id, value);
            return value;
        }

        pub fn get(self: *Self, key: Key, output: []u8) !?[]const u8 {
            const pinned = (try self.pin(key)) orelse return null;
            defer self.unpin(pinned.generation);

            return self.readPinned(pinned, key, output);
        }

        /// Keeps the size check and read under one pin.
        pub fn getSized(self: *Self, key: Key, output: []u8, required: *usize) !?[]const u8 {
            const pinned = (try self.pin(key)) orelse return null;
            defer self.unpin(pinned.generation);

            required.* = pinned.location.raw_len;
            if (output.len < pinned.location.raw_len) return error.BufferTooSmall;

            return self.readPinned(pinned, key, output);
        }

        pub fn getMany(self: *Self, requests: []const ReadRequest, results: []ReadResult) !void {
            std.debug.assert(requests.len == results.len);
            @memset(results, .{});
            const n = requests.len;
            if (n == 0) return;
            if (n > max_batch_keys) return error.TooManyKeys;

            var slots: [max_batch_keys]?BatchSlot = undefined;
            const generation = (try self.pinMany(requests, slots[0..n])) orelse return;
            defer self.unpin(generation);

            var order: [max_batch_keys]u8 = undefined;
            for (0..n) |i| order[i] = @intCast(i);
            sortByLocation(order[0..n], slots[0..n]);

            var stack_scratch: [inline_scratch_len]u8 = undefined;
            var verified_segment: ?u64 = null;

            for (order[0..n]) |idx| {
                const slot = slots[idx] orelse continue;
                const device = generation.devices[slot.segment_position];
                const key = requests[idx].key;
                const batch_id = slot.location.batch_id;

                if (self.options.cache) |cache| if (cache.get(self.io, key, batch_id, requests[idx].output)) |value| {
                    results[idx] = .{ .status = .ok, .required = value.len, .value = value };
                    continue;
                };

                if (verified_segment == null or verified_segment.? != slot.location.segment_id) {
                    try generation.index.verifySegmentHeader(device, slot.location.segment_id);
                    verified_segment = slot.location.segment_id;
                }

                const required = slot.location.raw_len;
                if (requests[idx].output.len < required) {
                    results[idx] = .{ .status = .buffer_too_small, .required = required };
                    continue;
                }

                const len = std.math.add(usize, entry.overhead, slot.location.stored_len) catch return error.InvalidLength;
                const scratch = if (len <= stack_scratch.len) stack_scratch[0..len] else try self.allocator.alloc(u8, len);
                defer if (len > stack_scratch.len) self.allocator.free(scratch);

                const value = (try generation.index.readIntoUnverified(key, device, scratch, requests[idx].output)) orelse
                    return error.IndexMismatch;
                if (self.options.cache) |cache| cache.put(self.io, key, batch_id, value);
                results[idx] = .{ .status = .ok, .required = required, .value = value };
            }
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
            if (a.location.segment_id != b.location.segment_id) return a.location.segment_id < b.location.segment_id;
            return a.location.offset < b.location.offset;
        }

        /// Swaps in the new generation and returns the old one.
        pub fn swap(self: *Self, generation: *Generation, next_writer: writer_module.Writer(Device)) *Generation {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const old = self.generation;
            self.generation = generation;
            self.writer = next_writer;
            return old;
        }

        /// Waits for all pins on a generation.
        pub fn drain(self: *Self, generation: *Generation) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (generation.readers != 0) self.idle.waitUncancelable(self.io, &self.mutex);
        }

        pub fn flush(self: *Self) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;

            try self.writer.flush();
        }

        pub fn close(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return;

            self.closing = true;
            const result = self.writer.flush();
            self.release();
            try result;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (!self.closed) {
                self.closing = true;
                self.release();
            }
        }

        /// Waits for pinned readers before freeing.
        fn release(self: *Self) void {
            while (self.generation.readers != 0) self.idle.waitUncancelable(self.io, &self.mutex);
            self.generation.destroy();
            self.allocator.free(self.scratch);
            self.closed = true;
        }
    };
}
