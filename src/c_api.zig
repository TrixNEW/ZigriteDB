const std = @import("std");
const db = @import("root.zig");
const allocator = std.heap.page_allocator;

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
        };
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
    mutex: std.Io.Mutex = .init,
    entries: []db.entry.Entry,
    compression: []u8,
    encoder: db.lz4.Encoder = .{},
    threshold: u32,
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
    const config = try options.native();
    const handle = try allocator.create(Handle);
    errdefer allocator.destroy(handle);
    handle.threaded = std.Io.Threaded.init(allocator, .{});
    errdefer handle.threaded.deinit();
    const io = handle.threaded.io();
    const dir = try std.Io.Dir.cwd().openDir(io, name, .{ .follow_symlinks = false });
    defer dir.close(io);
    handle.world = try db.World.open(allocator, io, dir, config);
    errdefer handle.world.deinit();
    handle.entries = try allocator.alloc(db.entry.Entry, db.batch.max_records);
    errdefer allocator.free(handle.entries);
    handle.compression = try allocator.alloc(u8, if (options.compression_threshold == 0) 0 else config.shard.batch_buffer_size);
    handle.mutex = .init;
    handle.threshold = options.compression_threshold;
    return handle;
}

pub export fn zg_close(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    const result = handle.world.close();
    allocator.free(handle.compression);
    allocator.free(handle.entries);
    handle.threaded.deinit();
    allocator.destroy(handle);
    result catch |err| return status(err);
    return .ok;
}

pub export fn zg_write(optional: ?*Handle, id: u64, operations: ?[*]const Operation, count: usize) Status {
    const handle = optional orelse return .invalid_argument;
    if (operations == null or count == 0 or id == 0) return .invalid_argument;
    if (count > db.batch.max_records) return .limit;
    const io = handle.threaded.io();
    handle.mutex.lock(io) catch |err| return status(err);
    defer handle.mutex.unlock(io);
    prepare(handle, id, operations.?[0..count]) catch |err| return status(err);
    _ = handle.world.write(.{ .entries = handle.entries[0..count] }) catch |err| return status(err);
    return .ok;
}

fn prepare(handle: *Handle, id: u64, operations: []const Operation) !void {
    var total: usize = 0;
    var used: usize = 0;
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
        if (handle.threshold != 0 and value.len >= handle.threshold and
            try db.lz4.bound(value.len) <= handle.compression.len - used)
        {
            item = try item.compress(&handle.encoder, handle.compression[used..]);
            if (item.header.compression == .lz4) used += item.value.len;
        }
        handle.entries[i] = item;
    }
}

pub export fn zg_get(optional: ?*Handle, key: ?*const Key, output: ?[*]u8, capacity: usize, required: ?*usize) Status {
    const length = required orelse return .invalid_argument;
    length.* = 0;
    const handle = optional orelse return .invalid_argument;
    const native = (key orelse return .invalid_argument).native() catch |err| return status(err);
    if (output == null and capacity != 0) return .invalid_argument;
    const io = handle.threaded.io();
    handle.mutex.lock(io) catch |err| return status(err);
    defer handle.mutex.unlock(io);
    const size = (handle.world.valueSize(native) catch |err| return status(err)) orelse return .not_found;
    length.* = size;
    if (capacity < size) return .buffer_too_small;
    const bytes: []u8 = if (output) |ptr| ptr[0..capacity] else &.{};
    _ = handle.world.get(native, bytes) catch |err| return status(err);
    return .ok;
}

pub export fn zg_flush(optional: ?*Handle) Status {
    const handle = optional orelse return .invalid_argument;
    const io = handle.threaded.io();
    handle.mutex.lock(io) catch |err| return status(err);
    defer handle.mutex.unlock(io);
    handle.world.flush() catch |err| return status(err);
    return .ok;
}

pub export fn zg_compact(optional: ?*Handle, dimension: i32, x: i32, z: i32) Status {
    const handle = optional orelse return .invalid_argument;
    const io = handle.threaded.io();
    handle.mutex.lock(io) catch |err| return status(err);
    defer handle.mutex.unlock(io);
    const result = (handle.world.compact(.{ .dimension = dimension, .x = x, .z = z }) catch |err| return status(err)) orelse return .not_found;
    return if (result.cleanup.failure != null or !result.cleanup.synced) .cleanup_pending else .ok;
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
        error.DirectoryBusy => .busy,
        error.NeedsRecovery => .needs_recovery,
        error.BatchOrder => .batch_order,
        error.BatchTooLarge, error.IndexFull, error.TooManySegments, error.SegmentFull => .limit,
        error.InvalidArgument, error.InvalidSubchunkY, error.RegionMismatch, error.InvalidBufferSize, error.InvalidShardLimit => .invalid_argument,
        error.InvalidMagic, error.ChecksumMismatch, error.InvalidCompressedData, error.TruncatedHeader, error.TruncatedRecord, error.TruncatedManifest, error.InvalidLength, error.InvalidCommit, error.BatchMismatch, error.IdentityMismatch, error.IncompleteBatch, error.InvalidGeneration, error.InvalidSegmentCount, error.InvalidSegmentId, error.InvalidSegmentOrder, error.InvalidActiveSegment, error.InvalidBatchId, error.InvalidCommitCount, error.IndexMismatch => .corruption,
        error.UnsupportedVersion, error.UnsupportedCompression, error.InvalidFlags, error.UnknownKind => .unsupported,
        else => .io_error,
    };
}
