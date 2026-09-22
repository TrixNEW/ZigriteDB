const std = @import("std");
const allocator = std.heap.page_allocator;

const db = @import("root.zig");

const abi_version: u32 = 1;
const max_path_length: usize = 4096;

pub export fn zg_abi_version() u32 {
    return abi_version;
}

pub export fn zg_platform_supported() c_int {
    return @intFromBool(db.directory.supported);
}

pub const Status = enum(c_int) {
    ok,
    not_found,
    invalid_argument,
    buffer_too_small,
    out_of_memory,
    unsupported,
    corruption,
    io_error,
    needs_recovery,
    busy,
    batch_order,
    limit,
    cleanup_pending,
    permission_denied,
    no_space,
    read_only,
};

pub export fn zg_status_message(code: c_int) [*:0]const u8 {
    const value = std.enums.fromInt(Status, code) orelse return "Unknown status";
    return switch (value) {
        .ok => "OK",
        .not_found => "Not found",
        .invalid_argument => "Invalid argument",
        .buffer_too_small => "Buffer too small",
        .out_of_memory => "Out of memory",
        .unsupported => "Unsupported platform or format",
        .corruption => "Corrupt data",
        .io_error => "I/O error",
        .needs_recovery => "Recovery required",
        .busy => "Store is busy",
        .batch_order => "Batch ID is out of order",
        .limit => "Storage or batch limit exceeded",
        .cleanup_pending => "Compaction succeeded; cleanup is pending",
        .permission_denied => "Permission denied",
        .no_space => "Disk full or quota exceeded",
        .read_only => "Read-only filesystem",
    };
}
pub const Options = extern struct {
    version: u32 = abi_version,
    struct_size: u32 = @sizeOf(Options),
    max_open_shards: u32 = 16,
    max_keys: u32 = 65536,
    max_segments: u32 = 64,
    batch_buffer_size: u32 = 1024 * 1024,
    max_segment_size: u64 = 256 * 1024 * 1024,
    buffered: u32 = 0,
    compression_threshold: u32 = 256,
    cache_bytes: u64 = 0,
    cache_shards: u32 = 16,
    reserved: u32 = 0,

    fn native(self: Options) !db.WorldOptions {
        if (self.version != abi_version or self.struct_size != @sizeOf(Options) or self.buffered > 1) return error.InvalidArgument;
        if (self.compression_threshold > db.record.max_value_len) return error.InvalidArgument;
        const result: db.WorldOptions = .{
            .max_open_shards = self.max_open_shards,
            .shard = .{
                .max_keys = self.max_keys,
                .max_segments = self.max_segments,
                .batch_buffer_size = self.batch_buffer_size,
                .max_segment_size = self.max_segment_size,
                .durability = if (self.buffered == 1) .buffered else .sync,
            },
            .cache = .{
                .bytes = std.math.cast(usize, self.cache_bytes) orelse return error.InvalidArgument,
                .shards = self.cache_shards,
            },
        };
        if (self.reserved != 0) return error.InvalidArgument;
        if (result.cache.shards == 0 or result.cache.shards > 1024) return error.InvalidArgument;
        if (result.max_open_shards == 0 or result.max_open_shards > 1024) return error.InvalidArgument;
        result.shard.validate() catch return error.InvalidArgument;
        return result;
    }
};

pub const Key = extern struct {
    dimension: i32,
    chunk_x: i32,
    chunk_z: i32,
    subchunk_y: i32,
    component: u32,

    fn native(self: Key) !db.Key {
        if (self.component > std.math.maxInt(u8)) return error.InvalidArgument;
        const result: db.Key = .{
            .dimension = self.dimension,
            .chunk_x = self.chunk_x,
            .chunk_z = self.chunk_z,
            .subchunk_y = self.subchunk_y,
            .component = std.enums.fromInt(db.Component, @as(u8, @intCast(self.component))) orelse return error.InvalidArgument,
        };
        _ = try result.encode();
        return result;
    }
};

pub const Region = extern struct {
    dimension: i32,
    x: i32,
    z: i32,
};

pub const Operation = extern struct {
    key: Key,
    remove: u32,
    value: ?[*]const u8,
    value_len: usize,
};

pub const Handle = struct {
    threaded: std.Io.Threaded,
    world: db.World,
    maintenance: @import("world/maintenance.zig").Queue(db.World, compactRegion),
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    writers: [4]?WriteContext = .{null} ** 4,
    writer_limit: usize,
    threshold: u32,
    stats: db.Stats = .{},

    fn acquireWriter(self: *Handle) !*WriteContext {
        const io = self.threaded.io();
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (true) {
            for (self.writers[0..self.writer_limit]) |*slot| {
                if (slot.* == null) slot.* = try WriteContext.init(self.threshold, self.world.options.shard.batch_buffer_size);
                const context = &slot.*.?;
                if (context.busy) continue;
                context.busy = true;
                return context;
            }
            try self.available.wait(io, &self.mutex);
        }
    }

    fn releaseWriter(self: *Handle, context: *WriteContext) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        context.busy = false;
        self.available.signal(io);
    }
};

const WriteContext = struct {
    entries: []db.entry.Entry,
    compression: []u8,
    encoder: db.lz4.Encoder = .{},
    threshold: u32,
    busy: bool = false,

    fn init(threshold: u32, size: usize) !WriteContext {
        const entries = try allocator.alloc(db.entry.Entry, db.batch.max_records);
        errdefer allocator.free(entries);
        return .{
            .entries = entries,
            .compression = try allocator.alloc(u8, if (threshold == 0) 0 else size),
            .threshold = threshold,
        };
    }

    fn deinit(self: *WriteContext) void {
        allocator.free(self.compression);
        allocator.free(self.entries);
    }
};

pub export fn zg_key_init(out: ?*Key, dimension: i32, x: i32, z: i32, component: u32, subchunk_y: i32) Status {
    const target = out orelse return .invalid_argument;
    const key: Key = .{
        .dimension = dimension,
        .chunk_x = x,
        .chunk_z = z,
        .component = component,
        .subchunk_y = subchunk_y,
    };
    _ = key.native() catch |err| return status(err);
    target.* = key;
    return .ok;
}
pub export fn zg_key_validate(key: ?*const Key) Status {
    const value = key orelse return .invalid_argument;
    _ = value.native() catch |err| return status(err);
    return .ok;
}

pub export fn zg_key_region(key: ?*const Key, out: ?*Region) Status {
    const target = out orelse return .invalid_argument;
    const value = (key orelse return .invalid_argument).native() catch |err| return status(err);
    const region = value.region();
    target.* = .{ .dimension = region.dimension, .x = region.x, .z = region.z };
    return .ok;
}
pub export fn zg_options_init(out: ?*Options) Status {
    (out orelse return .invalid_argument).* = .{};
    return .ok;
}

pub export fn zg_options_validate(options: ?*const Options) Status {
    const value = options orelse return .invalid_argument;
    _ = value.native() catch |err| return status(err);
    return .ok;
}
pub export fn zg_open(path: ?[*]const u8, length: usize, options: ?*const Options, out: ?*?*Handle) Status {
    const target = out orelse return .invalid_argument;
    target.* = null;
    target.* = open(path, length, if (options) |value| value.* else .{}) catch |err| return status(err);
    return .ok;
}

fn open(path: ?[*]const u8, length: usize, options: Options) !*Handle {
    const name = try pathSlice(path, length);
    var config = try options.native();
    const handle = try allocator.create(Handle);
    errdefer allocator.destroy(handle);
    handle.stats = .{};
    config.shard.stats = &handle.stats;
    handle.threaded = std.Io.Threaded.init(allocator, .{});
    errdefer handle.threaded.deinit();
    const io = handle.threaded.io();
    const dir = try std.Io.Dir.cwd().openDir(io, name, .{ .follow_symlinks = false });
    defer dir.close(io);
    handle.world = try db.World.open(allocator, io, dir, config);
    errdefer handle.world.deinit();
    handle.maintenance = .{ .io = io, .context = &handle.world };
    handle.mutex = .init;
    handle.available = .init;
    handle.writers = .{null} ** 4;
    handle.writer_limit = @min(4, config.max_open_shards);
    handle.threshold = options.compression_threshold;
    return handle;
}

pub export fn zg_close(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    const maintenance_result = handle.maintenance.close();
    const result = handle.world.close();
    for (&handle.writers) |*slot| if (slot.*) |*context| context.deinit();
    handle.threaded.deinit();
    allocator.destroy(handle);
    result catch |err| return status(err);
    maintenance_result catch |err| return status(err);
    return .ok;
}

pub export fn zg_write(optional: ?*Handle, id: u64, operations: ?[*]const Operation, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (operations == null or count == 0 or id == 0) return .invalid_argument;
    if (count > db.batch.max_records) return .limit;
    const context = handle.acquireWriter() catch |err| return status(err);
    defer handle.releaseWriter(context);
    _ = prepare(context, id, operations.?[0..count], 0, 0) catch |err| return status(err);
    _ = handle.world.write(.{ .entries = context.entries[0..count] }) catch |err| return status(err);
    return .ok;
}

pub const Batch = extern struct {
    id: u64,
    operations: ?[*]const Operation,
    count: usize,
};

pub export fn zg_write_group(optional: ?*Handle, input: ?[*]const Batch, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (input == null or count == 0) return .invalid_argument;
    if (count > @import("batch/group.zig").max_batches) return .limit;
    var total: usize = 0;
    var raw_bytes: usize = 0;
    for (input.?[0..count]) |batch| {
        if (batch.operations == null or batch.count == 0 or batch.id == 0) return .invalid_argument;
        total = std.math.add(usize, total, batch.count) catch return .limit;
        if (total > db.batch.max_records) return .limit;
        for (batch.operations.?[0..batch.count]) |operation| {
            raw_bytes = std.math.add(usize, raw_bytes, operation.value_len) catch return .limit;
            raw_bytes = std.math.add(usize, raw_bytes, db.entry.overhead) catch return .limit;
            if (raw_bytes > db.batch.max_bytes) return .limit;
        }
    }
    const context = handle.acquireWriter() catch |err| return status(err);
    defer handle.releaseWriter(context);
    var batches: [@import("batch/group.zig").max_batches]db.WriteBatch = undefined;
    var offset: usize = 0;
    var used: usize = 0;
    for (input.?[0..count], 0..) |batch, i| {
        used = prepare(context, batch.id, batch.operations.?[0..batch.count], offset, used) catch |err| return status(err);
        batches[i] = .{ .entries = context.entries[offset .. offset + batch.count] };
        offset += batch.count;
    }
    handle.world.writeGroup(batches[0..count]) catch |err| return status(err);
    return .ok;
}

fn prepare(context: *WriteContext, id: u64, operations: []const Operation, offset: usize, compression_offset: usize) !usize {
    var total: usize = 0;
    var used = compression_offset;
    for (operations, 0..) |operation, i| {
        if (operation.remove > 1) return error.InvalidArgument;
        if (operation.value_len > db.record.max_value_len) return error.BatchTooLarge;
        if (operation.value_len != 0 and (operation.value == null or operation.remove == 1)) return error.InvalidArgument;
        const value = if (operation.value) |ptr| ptr[0..operation.value_len] else &.{};
        total = try std.math.add(usize, total, db.entry.overhead + value.len);
        if (total > db.batch.max_bytes) return error.BatchTooLarge;
        var item: db.entry.Entry = .{
            .key = try operation.key.native(),
            .header = .{ .kind = if (operation.remove == 1) .delete else .put, .batch_id = id, .stored_len = @intCast(value.len), .raw_len = @intCast(value.len) },
            .value = value,
        };
        if (context.threshold != 0 and value.len >= context.threshold and
            try db.lz4.bound(value.len) <= context.compression.len - used)
        {
            item = try item.compress(&context.encoder, context.compression[used..]);
            if (item.header.compression == .lz4) used += item.value.len;
        }
        context.entries[offset + i] = item;
    }
    return used;
}

pub export fn zg_get(optional: ?*Handle, key: ?*const Key, output: ?[*]u8, capacity: usize, required: ?*usize) Status {
    const length = required orelse return .invalid_argument;
    length.* = 0;
    const handle = optional orelse return .invalid_argument;
    const native = (key orelse return .invalid_argument).native() catch |err| return status(err);
    if (output == null and capacity != 0) return .invalid_argument;
    const bytes: []u8 = if (output) |ptr| ptr[0..capacity] else &.{};
    _ = (handle.world.getSized(native, bytes, length) catch |err| return status(err)) orelse return .not_found;
    return .ok;
}

pub const ReadRequest = extern struct {
    key: Key,
    output: ?[*]u8,
    capacity: usize,
};

pub const ReadResult = extern struct {
    status: Status = .not_found,
    required: usize = 0,
};

const max_c_batch = 256;

/// Batch reads isolate per-key failures.
pub export fn zg_get_many(optional: ?*Handle, requests: ?[*]const ReadRequest, results: ?[*]ReadResult, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (requests == null or results == null or count == 0) return .invalid_argument;
    if (count > max_c_batch) return .limit;

    var native_requests: [max_c_batch]db.ReadRequest = undefined;
    var native_results: [max_c_batch]db.ReadResult = undefined;
    for (requests.?[0..count], 0..) |request, i| {
        const key = request.key.native() catch |err| return status(err);
        if (request.output == null and request.capacity != 0) return .invalid_argument;
        const bytes: []u8 = if (request.output) |ptr| ptr[0..request.capacity] else &.{};
        native_requests[i] = .{ .key = key, .output = bytes };
    }

    handle.world.getMany(native_requests[0..count], native_results[0..count]) catch |err| return status(err);

    for (native_results[0..count], 0..) |result, i| {
        results.?[i] = .{
            .status = switch (result.status) {
                .ok => .ok,
                .not_found => .not_found,
                .buffer_too_small => .buffer_too_small,
            },
            .required = result.required,
        };
    }
    return .ok;
}

pub export fn zg_flush(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    handle.world.flush() catch |err| return status(err);
    return .ok;
}

pub const StatsSnapshot = extern struct {
    get_calls: u64 = 0,
    writes: u64 = 0,
    records_written: u64 = 0,
    raw_bytes_written: u64 = 0,
    compressed_bytes_written: u64 = 0,
    disk_reads: u64 = 0,
    bytes_read: u64 = 0,
    fsync_count: u64 = 0,
    fsync_duration_ns: u64 = 0,
    segment_rotations: u64 = 0,
    compactions: u64 = 0,
    compaction_input_bytes: u64 = 0,
    compaction_output_bytes: u64 = 0,
    compaction_duration_ns: u64 = 0,
    recovery_attempts: u64 = 0,
    recovery_errors: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_evictions: u64 = 0,
};

pub export fn zg_stats_get(optional: ?*Handle, out: ?*StatsSnapshot) Status {
    const handle = optional orelse return .invalid_argument;
    const target = out orelse return .invalid_argument;
    inline for (std.meta.fields(StatsSnapshot)) |field| {
        @field(target, field.name) = @field(handle.stats, field.name).load(.monotonic);
    }
    return .ok;
}

pub export fn zg_stats_reset(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    handle.stats.reset();
    return .ok;
}

pub export fn zg_compact(optional: ?*Handle, dimension: i32, x: i32, z: i32) Status {
    const handle = optional orelse return .invalid_argument;
    const result = (handle.world.compact(.{ .dimension = dimension, .x = x, .z = z }) catch |err| return status(err)) orelse return .not_found;
    return if (result.cleanup.failure != null or !result.cleanup.synced) .cleanup_pending else .ok;
}

pub export fn zg_last_batch_id(optional: ?*Handle, dimension: i32, x: i32, z: i32, out: ?*u64) Status {
    const target = out orelse return .invalid_argument;
    target.* = 0;
    const handle = optional orelse return .invalid_argument;
    target.* = (handle.world.lastBatchId(.{ .dimension = dimension, .x = x, .z = z }) catch |err| return status(err)) orelse return .not_found;
    return .ok;
}

pub export fn zg_compact_async(optional: ?*Handle, dimension: i32, x: i32, z: i32) Status {
    const handle = optional orelse return .invalid_argument;
    handle.maintenance.submit(.{ .dimension = dimension, .x = x, .z = z }) catch |err| return status(err);
    return .ok;
}

pub export fn zg_maintenance_wait(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    handle.maintenance.wait() catch |err| return status(err);
    return .ok;
}

fn compactRegion(world: *db.World, region: db.Region) !void {
    const result = (try world.compact(region)) orelse return error.FileNotFound;
    if (result.cleanup.failure != null or !result.cleanup.synced) return error.CleanupPending;
}

pub export fn zg_recover_region(source: ?[*]const u8, source_len: usize, destination: ?[*]const u8, destination_len: usize, options: ?*const Options) Status {
    recover(source, source_len, destination, destination_len, if (options) |value| value.* else .{}) catch |err| return status(err);
    return .ok;
}

fn recover(source: ?[*]const u8, source_len: usize, destination: ?[*]const u8, destination_len: usize, options: Options) !void {
    const source_path = try pathSlice(source, source_len);
    const target_path = try pathSlice(destination, destination_len);
    const config = try options.native();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const input = try std.Io.Dir.cwd().openDir(io, source_path, .{ .follow_symlinks = false });
    defer input.close(io);
    const output = try std.Io.Dir.cwd().openDir(io, target_path, .{ .follow_symlinks = false });
    defer output.close(io);
    _ = try db.recovery_copy.recoverTo(allocator, io, input, output, .{
        .max_segments = config.shard.max_segments,
        .max_segment_size = config.shard.max_segment_size,
        .batch_buffer_size = config.shard.batch_buffer_size,
    });
}

fn pathSlice(ptr: ?[*]const u8, length: usize) ![]const u8 {
    if (ptr == null or length == 0 or length > max_path_length) return error.InvalidArgument;
    const path = ptr.?[0..length];
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    return path;
}

fn status(err: anyerror) Status {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.NoSpaceLeft, error.DiskQuota => .no_space,
        error.ReadOnlyFileSystem => .read_only,
        error.OutOfMemory => .out_of_memory,
        error.UnsupportedPlatform => .unsupported,
        error.FileNotFound => .not_found,
        error.BufferTooSmall => .buffer_too_small,
        error.DirectoryBusy, error.QueueFull, error.AlreadyQueued => .busy,
        error.CleanupPending => .cleanup_pending,
        error.NeedsRecovery, error.MissingManifest => .needs_recovery,
        error.BatchOrder => .batch_order,
        error.BatchTooLarge, error.IndexFull, error.TooManySegments, error.SegmentFull, error.GenerationExhausted, error.SegmentIdExhausted, error.TooManyKeys => .limit,
        error.InvalidArgument, error.InvalidSubchunkY, error.RegionMismatch, error.InvalidBufferSize, error.InvalidShardLimit => .invalid_argument,
        error.InvalidMagic, error.ChecksumMismatch, error.InvalidCompressedData, error.TruncatedHeader, error.TruncatedRecord, error.TruncatedManifest, error.InvalidLength, error.InvalidCommit, error.BatchMismatch, error.IdentityMismatch, error.IncompleteBatch, error.InvalidGeneration, error.InvalidSegmentCount, error.InvalidSegmentId, error.InvalidSegmentOrder, error.InvalidActiveSegment, error.InvalidBatchId, error.InvalidCommitCount, error.IndexMismatch, error.MissingSegment => .corruption,
        error.UnsupportedVersion, error.UnsupportedCompression, error.InvalidFlags, error.UnknownKind => .unsupported,
        else => .io_error,
    };
}
