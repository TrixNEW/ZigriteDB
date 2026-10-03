const std = @import("std");
const allocator = std.heap.c_allocator;

const db = @import("root.zig");

const abi_version: u32 = 3;
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
    needs_migration,
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
        .needs_migration => "World uses an older format; run zigrite migrate",
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
    buffered: u32 = 1,
    compression_threshold: u32 = 256,
    cache_bytes: u64 = 0,
    cache_shards: u32 = 16,
    skip_unchanged: u32 = 0,
    compact_min_bytes: u64 = 16 * 1024 * 1024,
    compact_live_percent: u32 = 50,
    reserved: u32 = 0,

    fn read(options: *const Options) !Options {
        const prefix: *const [2]u32 = @ptrCast(options);
        if (prefix[0] != abi_version or prefix[1] != @sizeOf(Options)) return error.InvalidArgument;
        return options.*;
    }

    fn native(self: Options) !db.WorldOptions {
        if (self.version != abi_version or self.struct_size != @sizeOf(Options) or self.buffered > 1 or
            self.skip_unchanged > 1 or self.compact_live_percent > 100 or self.reserved != 0) return error.InvalidArgument;
        if (self.compression_threshold > db.record.max_value_len) return error.InvalidArgument;
        const result: db.WorldOptions = .{
            .max_open_regions = self.max_open_shards,
            .region = .{
                .max_keys = self.max_keys,
                .max_segments = self.max_segments,
                .batch_buffer_size = self.batch_buffer_size,
                .max_segment_size = self.max_segment_size,
                .durability = if (self.buffered == 1) .buffered else .sync,
                .compression_threshold = self.compression_threshold,
                .skip_unchanged = self.skip_unchanged == 1,
                .compact_min_bytes = self.compact_min_bytes,
                .compact_live_percent = @intCast(self.compact_live_percent),
            },
            .cache = .{
                .bytes = std.math.cast(usize, self.cache_bytes) orelse return error.InvalidArgument,
                .shards = self.cache_shards,
            },
        };
        if (result.cache.shards == 0 or result.cache.shards > 1024) return error.InvalidArgument;
        if (result.max_open_regions == 0 or result.max_open_regions > 1024) return error.InvalidArgument;
        result.region.validate() catch return error.InvalidArgument;
        return result;
    }
};

comptime {
    std.debug.assert(@sizeOf(Options) == 72);
    std.debug.assert(@offsetOf(Options, "struct_size") == 4);
    std.debug.assert(@offsetOf(Options, "compression_threshold") == 36);
    std.debug.assert(@offsetOf(Options, "cache_bytes") == 40);
    std.debug.assert(@offsetOf(Options, "skip_unchanged") == 52);
    std.debug.assert(@offsetOf(Options, "compact_min_bytes") == 56);
    std.debug.assert(@offsetOf(Options, "compact_live_percent") == 64);
}

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
            .component = @enumFromInt(@as(u8, @intCast(self.component))),
        };
        try result.validate();
        return result;
    }

    fn from(key: db.Key) Key {
        return .{
            .dimension = key.dimension,
            .chunk_x = key.chunk_x,
            .chunk_z = key.chunk_z,
            .subchunk_y = key.subchunk_y,
            .component = @intFromEnum(key.component),
        };
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

pub const Batch = extern struct {
    id: u64,
    operations: ?[*]const Operation,
    count: usize,
};

const Maintenance = @import("world/maintenance.zig");

pub const Handle = struct {
    threaded: std.Io.Threaded,
    world: db.World,
    maintenance: Maintenance.Queue(db.World, compactRegion),
    // Stale regions found by writes; dropped on close.
    compaction: Maintenance.WorkQueue(db.World, db.Region, 16, false, compactStale),
    prefetch: Maintenance.WorkQueue(db.World, db.Key, 256, false, warmKey),
    stats: db.Stats = .{},
};

pub export fn zg_key_init(out: ?*Key, dimension: i32, x: i32, z: i32, component: u32, subchunk_y: i32) Status {
    const target = out orelse return .invalid_argument;
    const key: Key = .{ .dimension = dimension, .chunk_x = x, .chunk_z = z, .component = component, .subchunk_y = subchunk_y };
    _ = key.native() catch |err| return status(err);
    target.* = key;
    return .ok;
}

pub export fn zg_key_validate(key: ?*const Key) Status {
    _ = (key orelse return .invalid_argument).native() catch |err| return status(err);
    return .ok;
}

pub export fn zg_key_region(key: ?*const Key, out: ?*Region) Status {
    const target = out orelse return .invalid_argument;
    const region = ((key orelse return .invalid_argument).native() catch |err| return status(err)).region();
    target.* = .{ .dimension = region.dimension, .x = region.x, .z = region.z };
    return .ok;
}

pub export fn zg_options_init(out: ?*Options) Status {
    (out orelse return .invalid_argument).* = .{};
    return .ok;
}

pub export fn zg_options_validate(options: ?*const Options) Status {
    const value = options orelse return .invalid_argument;
    _ = (Options.read(value) catch |err| return status(err)).native() catch |err| return status(err);
    return .ok;
}

pub export fn zg_open(path: ?[*]const u8, length: usize, options: ?*const Options, out: ?*?*Handle) Status {
    const target = out orelse return .invalid_argument;
    target.* = null;
    const config = if (options) |value| Options.read(value) catch |err| return status(err) else Options{};
    target.* = open(path, length, config) catch |err| return status(err);
    return .ok;
}

fn open(path: ?[*]const u8, length: usize, options: Options) !*Handle {
    const name = try pathSlice(path, length);
    var config = try options.native();
    const handle = try allocator.create(Handle);
    errdefer allocator.destroy(handle);
    handle.stats = .{};
    config.region.stats = &handle.stats;
    handle.threaded = std.Io.Threaded.init(allocator, .{});
    errdefer handle.threaded.deinit();
    const io = handle.threaded.io();
    const dir = try std.Io.Dir.cwd().openDir(io, name, .{ .follow_symlinks = false });
    defer dir.close(io);
    handle.world = try db.World.open(allocator, io, dir, config);
    handle.maintenance = .{ .io = io, .context = &handle.world };
    handle.compaction = .{ .io = io, .context = &handle.world };
    handle.world.compactor = .{ .context = handle, .submit = submitCompaction };
    handle.prefetch = .{ .io = io, .context = &handle.world };
    return handle;
}

pub export fn zg_close(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    handle.prefetch.close() catch {};
    handle.compaction.close() catch {};
    const maintenance_result = handle.maintenance.close();
    const result = handle.world.close();
    handle.threaded.deinit();
    allocator.destroy(handle);
    result catch |err| return status(err);
    maintenance_result catch |err| return status(err);
    return .ok;
}

// Most saves are a handful of records; larger ones use the heap.
const inline_entries = 64;

fn entries(operations: []const Operation, buffer: []db.Entry) ![]db.Entry {
    for (operations, buffer[0..operations.len]) |operation, *entry| {
        if (operation.remove > 1) return error.InvalidArgument;
        if (operation.value_len > db.record.max_value_len) return error.BatchTooLarge;
        if (operation.value_len != 0 and (operation.value == null or operation.remove == 1)) return error.InvalidArgument;
        entry.* = .{
            .key = try operation.key.native(),
            .value = if (operation.remove == 1) null else if (operation.value) |ptr| ptr[0..operation.value_len] else &.{},
        };
    }
    return buffer[0..operations.len];
}

pub export fn zg_write(optional: ?*Handle, id: u64, operations: ?[*]const Operation, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (operations == null or count == 0) return .invalid_argument;
    if (count > db.frame.max_records) return .limit;
    var stack: [inline_entries]db.Entry = undefined;
    const buffer = if (count <= stack.len) stack[0..count] else allocator.alloc(db.Entry, count) catch return .out_of_memory;
    defer if (count > stack.len) allocator.free(buffer);
    const list = entries(operations.?[0..count], buffer) catch |err| return status(err);
    _ = handle.world.write(.{ .id = id, .entries = list }) catch |err| return status(err);
    return .ok;
}

pub export fn zg_write_group(optional: ?*Handle, input: ?[*]const Batch, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (input == null or count == 0) return .invalid_argument;
    if (count > db.write.max_group_batches) return .limit;
    var total: usize = 0;
    for (input.?[0..count]) |batch| {
        if (batch.operations == null or batch.count == 0) return .invalid_argument;
        total = std.math.add(usize, total, batch.count) catch return .limit;
        if (total > db.frame.max_records) return .limit;
    }
    const buffer = allocator.alloc(db.Entry, total) catch return .out_of_memory;
    defer allocator.free(buffer);
    var batches: [db.write.max_group_batches]db.WriteBatch = undefined;
    var offset: usize = 0;
    for (input.?[0..count], batches[0..count]) |batch, *native| {
        const list = entries(batch.operations.?[0..batch.count], buffer[offset..]) catch |err| return status(err);
        native.* = .{ .id = batch.id, .entries = list };
        offset += batch.count;
    }
    _ = handle.world.writeGroup(batches[0..count]) catch |err| return status(err);
    return .ok;
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

const max_c_batch = db.World.max_read_batch;
// Kept small: ReleaseSafe fills undefined stack arrays.
const read_chunk = 32;

pub export fn zg_get_many(optional: ?*Handle, requests: ?[*]const ReadRequest, results: ?[*]ReadResult, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (requests == null or results == null or count == 0) return .invalid_argument;
    if (count > max_c_batch) return .limit;
    for (requests.?[0..count]) |request| {
        _ = request.key.native() catch |err| return status(err);
        if (request.output == null and request.capacity != 0) return .invalid_argument;
    }
    var start: usize = 0;
    while (start < count) : (start += read_chunk) {
        const end = @min(count, start + read_chunk);
        var native_requests: [read_chunk]db.ReadRequest = undefined;
        var native_results: [read_chunk]db.ReadResult = undefined;
        for (requests.?[start..end], native_requests[0 .. end - start]) |request, *native| {
            const bytes: []u8 = if (request.output) |ptr| ptr[0..request.capacity] else &.{};
            native.* = .{ .key = request.key.native() catch unreachable, .output = bytes };
        }
        handle.world.getMany(native_requests[0 .. end - start], native_results[0 .. end - start]) catch |err| return status(err);
        for (native_results[0 .. end - start], results.?[start..end]) |result, *target| {
            target.* = .{
                .status = switch (result.status) {
                    .ok => .ok,
                    .not_found => .not_found,
                    .buffer_too_small => .buffer_too_small,
                },
                .required = result.required,
            };
        }
    }
    return .ok;
}

pub const ChunkRecord = extern struct {
    component: u32,
    subchunk_y: i32,
    offset: usize,
    length: usize,
};

const inline_chunk_records = 64;

/// Reads a whole chunk: values are packed into `buffer`, described by `records`.
pub export fn zg_get_chunk(
    optional: ?*Handle,
    dimension: i32,
    chunk_x: i32,
    chunk_z: i32,
    buffer: ?[*]u8,
    capacity: usize,
    records: ?[*]ChunkRecord,
    record_capacity: usize,
    count: ?*usize,
    required: ?*usize,
) Status {
    const total = count orelse return .invalid_argument;
    const bytes_needed = required orelse return .invalid_argument;
    total.* = 0;
    bytes_needed.* = 0;
    const handle = optional orelse return .invalid_argument;
    if ((buffer == null and capacity != 0) or (records == null and record_capacity != 0)) return .invalid_argument;
    var stack: [inline_chunk_records]db.ChunkRecord = undefined;
    const native = if (record_capacity <= stack.len) stack[0..record_capacity] else allocator.alloc(db.ChunkRecord, record_capacity) catch return .out_of_memory;
    defer if (record_capacity > stack.len) allocator.free(native);
    const output: []u8 = if (buffer) |ptr| ptr[0..capacity] else &.{};
    var result: db.ChunkResult = undefined;
    handle.world.getChunk(dimension, chunk_x, chunk_z, output, native, &result) catch |err| {
        total.* = result.count;
        bytes_needed.* = result.required;
        return status(err);
    };
    total.* = result.count;
    bytes_needed.* = result.required;
    if (result.count == 0) return .not_found;
    for (native[0..result.count], records.?[0..result.count]) |record, *target| {
        target.* = .{
            .component = @intFromEnum(record.component),
            .subchunk_y = record.subchunk_y,
            .offset = @intFromPtr(record.value.ptr) - @intFromPtr(output.ptr),
            .length = record.value.len,
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
    unchanged_write_skips: u64 = 0,
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

pub export fn zg_prefetch(optional: ?*Handle, keys: ?[*]const Key, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (count == 0) return .ok;
    for ((keys orelse return .invalid_argument)[0..count]) |key| {
        const native = key.native() catch |err| return status(err);
        handle.prefetch.submit(native) catch |err| switch (err) {
            error.QueueFull, error.AlreadyQueued => {},
            else => return status(err),
        };
    }
    return .ok;
}

pub export fn zg_list_regions(optional: ?*Handle, out: ?[*]Region, capacity: usize, count: ?*usize) Status {
    const handle = optional orelse return .invalid_argument;
    const total = count orelse return .invalid_argument;
    if (capacity != 0 and out == null) return .invalid_argument;
    const found = handle.world.regions(allocator) catch |err| return status(err);
    defer allocator.free(found);
    total.* = found.len;
    for (found[0..@min(found.len, capacity)], 0..) |region, i| {
        out.?[i] = .{ .dimension = region.dimension, .x = region.x, .z = region.z };
    }
    return if (found.len > capacity) .buffer_too_small else .ok;
}

/// `component` filters to one component; ZG_ALL_COMPONENTS keeps every key.
pub export fn zg_list_keys(optional: ?*Handle, dimension: i32, x: i32, z: i32, component: u32, out: ?[*]Key, capacity: usize, count: ?*usize) Status {
    const handle = optional orelse return .invalid_argument;
    const total = count orelse return .invalid_argument;
    if (capacity != 0 and out == null) return .invalid_argument;
    const filter: db.KeyFilter = if (component == std.math.maxInt(u32))
        .{}
    else if (component <= std.math.maxInt(u8))
        .only(&.{@enumFromInt(@as(u8, @intCast(component)))})
    else
        return .invalid_argument;
    const region: db.Region = .{ .dimension = dimension, .x = x, .z = z };
    const found = handle.world.keys(region, allocator, filter) catch |err| return status(err);
    defer allocator.free(found);
    total.* = found.len;
    for (found[0..@min(found.len, capacity)], 0..) |key, i| out.?[i] = .from(key);
    return if (found.len > capacity) .buffer_too_small else .ok;
}

fn warmKey(world: *db.World, key: db.Key) !void {
    world.warm(key) catch {};
}

fn submitCompaction(context: *anyopaque, region: db.Region) void {
    const handle: *Handle = @ptrCast(@alignCast(context));
    handle.compaction.submit(region) catch {};
}

fn compactStale(world: *db.World, region: db.Region) !void {
    _ = world.compact(region) catch {};
}

fn compactRegion(world: *db.World, region: db.Region) !void {
    const result = (try world.compact(region)) orelse return error.FileNotFound;
    if (result.cleanup.failure != null or !result.cleanup.synced) return error.CleanupPending;
}

pub export fn zg_recover_region(source: ?[*]const u8, source_len: usize, destination: ?[*]const u8, destination_len: usize, options: ?*const Options) Status {
    const config = if (options) |value| Options.read(value) catch |err| return status(err) else Options{};
    recover(source, source_len, destination, destination_len, config) catch |err| return status(err);
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
        .max_segments = config.region.max_segments,
        .max_segment_size = config.region.max_segment_size,
        .batch_buffer_size = config.region.batch_buffer_size,
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
        error.NeedsMigration => .needs_migration,
        error.BatchOrder => .batch_order,
        error.BatchTooLarge, error.IndexFull, error.TooManySegments, error.SegmentFull, error.GenerationExhausted, error.SegmentIdExhausted, error.TooManyKeys => .limit,
        error.InvalidArgument, error.InvalidSubchunkY, error.RegionMismatch, error.InvalidBufferSize, error.InvalidRegionLimit, error.InvalidSegmentSize, error.EmptyBatch => .invalid_argument,
        error.InvalidMagic, error.ChecksumMismatch, error.InvalidCompressedData, error.TruncatedHeader, error.TruncatedRecord, error.TruncatedFrame, error.TruncatedManifest, error.InvalidLength, error.InvalidFrame, error.BatchMismatch, error.IdentityMismatch, error.IncompleteBatch, error.InvalidGeneration, error.InvalidSegmentCount, error.InvalidSegmentId, error.InvalidSegmentOrder, error.InvalidActiveSegment, error.IndexMismatch, error.MissingSegment, error.InvalidFormatFile => .corruption,
        error.UnsupportedVersion, error.UnsupportedCompression, error.InvalidFlags => .unsupported,
        else => .io_error,
    };
}
