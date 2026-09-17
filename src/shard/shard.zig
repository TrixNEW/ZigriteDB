const std = @import("std");

const commit = @import("../batch/commit.zig");
const WriteBatch = @import("../batch/write.zig").WriteBatch;
const entry = @import("../format/entry.zig");
const Key = @import("../format/key.zig").Key;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const index_module = @import("../index/index.zig");
const writer_module = @import("../storage/writer.zig");

pub const Options = struct {
    max_keys: u32 = 65536,
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    batch_buffer_size: usize = 1024 * 1024,
    durability: writer_module.Durability = .sync,

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
        index: index_module.Index,
        options: Options,
        scratch: []u8,
        devices: []Device,
        segment_ids: []u64,
        segment_count: usize,
        mutex: std.Io.Mutex = .init,
        closed: bool = false,

        const Self = @This();

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

            const writer = try writer_module.Writer(Device).create(device, header, options.max_segment_size, 0);

            return .{
                .allocator = allocator,
                .io = io,
                .writer = writer,
                .index = .{
                    .allocator = allocator,
                    .region = header.region,
                    .generation = header.generation,
                    .max_keys = options.max_keys,
                },
                .options = options,
                .scratch = scratch,
                .devices = devices,
                .segment_ids = ids,
                .segment_count = 1,
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

            if (index.has_tail) return error.NeedsRecovery;

            const active = source_devices.len - 1;
            const device = devices[active];
            if (try device.length() != index.active_offset) return error.FileChanged;

            try device.sync();

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
                },
                .index = index,
                .options = options,
                .scratch = scratch,
                .devices = devices,
                .segment_ids = ids,
                .segment_count = source_devices.len,
            };
        }

        pub fn rotate(self: *Self, device: Device, id: u64, publisher: anytype) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;
            if (self.writer.failed) return error.WriterFailed;
            if (self.segment_count == self.options.max_segments) return error.TooManySegments;
            if (id <= self.writer.header.segment_id) return error.InvalidSegmentOrder;
            if (try device.length() != 0) return error.FileNotEmpty;

            const count = self.segment_count + 1;
            const buffer = try self.allocator.alloc(u8, manifest.header_len + count * 8 + 4);
            defer self.allocator.free(buffer);

            self.segment_ids[self.segment_count] = id;
            const bytes = try (manifest.Manifest{
                .generation = self.index.generation,
                .region = self.index.region,
                .segments = self.segment_ids[0..count],
            }).encode(buffer);

            try self.writer.flush();

            const next = try writer_module.Writer(Device).create(device, .{
                .segment_id = id,
                .generation = self.index.generation,
                .region = self.index.region,
            }, self.options.max_segment_size, self.writer.last_batch_id);

            publisher.publish(bytes) catch |err| {
                self.writer.failed = true;
                return err;
            };

            self.devices[self.segment_count] = device;
            self.segment_count = count;
            self.writer = next;
            self.index.active_offset = segment.encoded_len;
        }
        pub fn write(self: *Self, batch: WriteBatch) !writer_module.AppendResult {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;
            if (self.writer.failed) return error.WriterFailed;

            const bytes = try batch.encode(self.scratch[0..self.options.batch_buffer_size]);
            const end = std.math.add(u64, self.writer.offset, bytes.len) catch return error.SegmentFull;
            if (end > self.options.max_segment_size) return error.SegmentFull;

            var prepared = try self.index.prepare(.{
                .id = batch.entries[0].header.batch_id,
                .records = bytes[0 .. bytes.len - commit.commit_len],
                .end_offset = std.math.cast(usize, end) orelse return error.InvalidLength,
            }, self.writer.header.segment_id);
            defer prepared.deinit();

            const result = try self.writer.appendEncoded(bytes, self.options.durability);
            self.index.publish(&prepared);
            self.index.active_offset = @intCast(result.end);

            return result;
        }

        pub fn get(self: *Self, key: Key, output: []u8) !?[]const u8 {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.closed) return error.Closed;

            const location = (try self.index.get(key)) orelse return null;

            for (self.segment_ids[0..self.segment_count], self.devices[0..self.segment_count]) |id, device| {
                if (id == location.segment_id) return self.index.readInto(key, device, self.scratch, output);
            }

            return error.IndexMismatch;
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

            const result = self.writer.flush();
            self.release();
            try result;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (!self.closed) self.release();
        }

        fn release(self: *Self) void {
            self.index.deinit();
            self.allocator.free(self.scratch);
            self.allocator.free(self.devices);
            self.allocator.free(self.segment_ids);
            self.closed = true;
        }
    };
}
