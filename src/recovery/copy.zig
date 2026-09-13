const std = @import("std");

const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");
const File = @import("../io/file.zig").File;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const publication = @import("../storage/publication.zig");
const Scanner = @import("file_scan.zig").Scanner(File);
const index_module = @import("../index/index.zig");
const entry = @import("../format/entry.zig");
const commit = @import("../batch/commit.zig");
const Batch = @import("scan.zig").Batch;
const CompactionOutput = @import("../storage/compaction_output.zig").CompactionOutput;
const shard = @import("../shard/shard.zig");

pub const Options = struct {
    max_keys: u32 = 65536,
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    batch_buffer_size: usize = 1024 * 1024,
    output_segment_size: ?u64 = null,
};

pub const Result = struct {
    segment_count: usize,
    committed_batches: u64 = 0,
    last_batch_id: u64 = 0,
    omitted_tail_bytes: u64 = 0,
    reclaimed_bytes: u64 = 0,
    source_bytes: u64 = 0,
    output_bytes: u64 = 0,
};

/// Copies committed data into an empty directory and preserves the source.
pub fn recoverTo(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, destination: std.Io.Dir, options: Options) !Result {
    return copyTo(false, allocator, io, source, destination, options);
}

/// Removes obsolete records while preserving the source and batch sequence.
pub fn compactTo(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, destination: std.Io.Dir, options: Options) !Result {
    return copyTo(true, allocator, io, source, destination, options);
}

fn copyTo(comptime compact: bool, allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, destination: std.Io.Dir, options: Options) !Result {
    try (shard.Options{
        .max_segments = options.max_segments,
        .max_segment_size = options.max_segment_size,
        .batch_buffer_size = options.batch_buffer_size,
    }).validate();

    const output_size = options.output_segment_size orelse options.max_segment_size;
    if (compact and output_size < segment.encoded_len) return error.SegmentFull;

    var input = try Directory.init(source, io);
    defer input.deinit();
    var output = try Directory.init(destination, io);
    defer output.deinit();
    var iterator = output.dir.iterate();
    if (try iterator.next(io) != null) return error.DirectoryNotEmpty;

    const handle = try files.openManifest(input.dir, io);
    defer handle.close(io);
    const file: File = .{ .handle = handle, .io = io };
    const length = try file.length();
    if (length > manifest.max_encoded_len) return error.ManifestTooLarge;

    const bytes = try allocator.alloc(u8, @intCast(length));
    defer allocator.free(bytes);
    const ids = try allocator.alloc(u64, options.max_segments);
    defer allocator.free(ids);
    const scratch = try allocator.alloc(u8, options.batch_buffer_size + segment.encoded_len);
    defer allocator.free(scratch);
    try file.readExact(bytes, 0);
    const metadata = try manifest.decode(bytes, ids);
    var live: ?index_module.Index = if (compact) try rebuild(allocator, io, input.dir, metadata, options, scratch) else null;
    defer if (live) |*index| index.deinit();
    if (live) |index| {
        if (index.has_tail) return error.NeedsRecovery;
    }
    const filtered = try allocator.alloc(u8, if (compact) options.batch_buffer_size else 0);
    defer allocator.free(filtered);
    const output_ids = try allocator.alloc(u64, if (compact) options.max_segments else 0);
    defer allocator.free(output_ids);
    const output_manifest = try allocator.alloc(u8, if (compact) manifest.header_len + options.max_segments * 8 + 4 else 0);
    defer allocator.free(output_manifest);
    var merged: CompactionOutput = .{
        .io = io,
        .dir = output.dir,
        .generation = metadata.generation,
        .region = metadata.region,
        .max_size = output_size,
        .ids = output_ids,
    };
    defer merged.deinit();
    var result: Result = .{ .segment_count = metadata.segments.len };

    for (metadata.segments, 0..) |id, position| {
        const original = try files.openSegment(input.dir, io, metadata.generation, id, false);
        defer original.close(io);
        var scanner = try Scanner.init(.{ .handle = original, .io = io }, .{
            .generation = metadata.generation,
            .segment_id = id,
            .region = metadata.region,
        }, if (position == metadata.segments.len - 1) .active else .sealed, result.last_batch_id, options.max_segment_size);

        result.source_bytes = try std.math.add(u64, result.source_bytes, scanner.length);
        const copied: ?std.Io.File = if (compact) null else try files.createSegment(output.dir, io, metadata.generation, id);
        defer if (copied) |opened| opened.close(io);
        const target: ?File = if (copied) |opened| .{ .handle = opened, .io = io } else null;
        if (target) |device| try device.writeAll(&(try scanner.header.encode()), 0);
        var offset: usize = segment.encoded_len;

        while (try scanner.next(scratch)) |batch| {
            const size = batch.records.len + commit.commit_len;
            const data = if (compact)
                try compactBatch(&live.?, id, batch, filtered)
            else
                scratch[segment.encoded_len..][0..size];
            if (compact) try merged.append(data) else try target.?.writeAll(data, offset);
            offset += data.len;

            if (data.len != 0) result.committed_batches = try std.math.add(u64, result.committed_batches, 1);
        }
        if (target) |device| {
            try device.sync();
            result.output_bytes = try std.math.add(u64, result.output_bytes, offset);
        }
        result.last_batch_id = scanner.last_batch_id;
        result.omitted_tail_bytes = scanner.length - scanner.offset;
    }

    var publisher: publication.Publisher(*Directory) = .{ .backend = &output };
    if (compact) {
        try merged.finish();
        result.segment_count = merged.count;
        result.output_bytes = merged.bytes;
        const rewritten = try (manifest.Manifest{
            .generation = metadata.generation,
            .region = metadata.region,
            .segments = output_ids[0..merged.count],
        }).encode(output_manifest);
        try publisher.publish(rewritten);
    } else {
        try publisher.publish(bytes);
    }
    result.reclaimed_bytes = (result.source_bytes - result.omitted_tail_bytes) -| result.output_bytes;
    return result;
}

fn rebuild(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, metadata: manifest.Manifest, options: Options, scratch: []u8) !index_module.Index {
    const devices = try allocator.alloc(File, metadata.segments.len);
    defer allocator.free(devices);
    var opened: usize = 0;
    defer for (devices[0..opened]) |device| device.handle.close(io);
    for (metadata.segments) |id| {
        devices[opened] = .{
            .handle = try files.openSegment(dir, io, metadata.generation, id, false),
            .io = io,
        };
        opened += 1;
    }
    return index_module.rebuildFiles(allocator, metadata, devices, options.max_keys, scratch, options.max_segment_size);
}

fn compactBatch(index: *const index_module.Index, segment_id: u64, batch: Batch, output: []u8) ![]const u8 {
    const start = batch.end_offset - commit.commit_len - batch.records.len;
    var read: usize = 0;
    var written: usize = 0;
    while (read < batch.records.len) {
        const decoded = try entry.decode(batch.records[read..]);
        const location = try index.get(decoded.entry.key);
        // The final batch preserves the last batch ID, even when no keys remain.
        const keep = batch.id == index.last_batch_id or if (location) |live|
            live.segment_id == segment_id and live.offset == start + read
        else
            false;
        if (keep) {
            @memcpy(output[written..][0..decoded.consumed], batch.records[read..][0..decoded.consumed]);
            written += decoded.consumed;
        }
        read += decoded.consumed;
    }
    if (written == 0) return output[0..0];
    const marker = try commit.seal(output[0..written]);
    @memcpy(output[written..][0..commit.commit_len], &marker);
    return output[0 .. written + commit.commit_len];
}
