const std = @import("std");

const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const File = @import("../io/file.zig").File;
const Store = @import("../region/store.zig").Store;
const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");
const publication = @import("../storage/publication.zig");
const scan = @import("scan.zig");
const Stats = @import("../stats.zig").Stats;

const Scanner = scan.FileScanner(File);

pub const Options = struct {
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    batch_buffer_size: usize = 1024 * 1024,
    stats: ?*Stats = null,
};

pub const Result = struct {
    segment_count: usize,
    committed_batches: u64 = 0,
    last_batch_id: u64 = 0,
    omitted_tail_bytes: u64 = 0,
    source_bytes: u64 = 0,
    output_bytes: u64 = 0,
};

/// Copies every verified frame of a region into an empty directory, dropping a torn active tail.
/// The source is never modified.
pub fn recoverTo(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, destination: std.Io.Dir, options: Options) !Result {
    if (options.stats) |s| _ = s.recovery_attempts.fetchAdd(1, .monotonic);
    errdefer if (options.stats) |s| {
        _ = s.recovery_errors.fetchAdd(1, .monotonic);
    };

    var input = try Directory.init(source, io);
    defer input.deinit();
    var output = try Directory.init(destination, io);
    defer output.deinit();
    var iterator = output.dir.iterate();
    if (try iterator.next(io) != null) return error.DirectoryNotEmpty;

    const ids = try allocator.alloc(u64, manifest.max_segments);
    defer allocator.free(ids);
    const metadata, const bytes = try Store.readManifest(allocator, io, input.dir, ids);
    defer allocator.free(bytes);
    if (metadata.segments.len > options.max_segments) return error.InvalidSegmentCount;
    const scratch = try allocator.alloc(u8, options.batch_buffer_size);
    defer allocator.free(scratch);

    var result: Result = .{ .segment_count = metadata.segments.len };
    var order: scan.Order = .{ .last_batch_id = metadata.base_batch_id };
    var created: usize = 0;
    errdefer for (metadata.segments[0..created]) |id| files.removeSegment(output.dir, io, metadata.generation, id) catch {};
    for (metadata.segments, 0..) |id, position| {
        const original = try files.openSegment(input.dir, io, metadata.generation, id, false);
        defer original.close(io);
        var scanner = try Scanner.init(.{ .handle = original, .io = io }, .{
            .generation = metadata.generation,
            .segment_id = id,
            .region = metadata.region,
            .salt = metadata.salt,
        }, if (position == metadata.segments.len - 1) .active else .sealed, order, options.max_segment_size);
        result.source_bytes += scanner.length;

        const copy = try files.createSegment(output.dir, io, metadata.generation, id);
        created += 1;
        defer copy.close(io);
        const target: File = .{ .handle = copy, .io = io };
        try target.writeAll(&(try scanner.header.encode()), 0);
        var offset: u64 = segment.encoded_len;
        while (try scanner.next(scratch)) |batch| {
            try target.writeAll(batch.bytes, offset);
            offset += batch.bytes.len;
            result.committed_batches += 1;
        }
        try target.sync();
        order = scanner.order;
        result.output_bytes += offset;
        result.omitted_tail_bytes = scanner.length - scanner.offset;
    }
    result.last_batch_id = order.last_batch_id;

    var publisher: publication.Publisher(*Directory) = .{ .backend = &output };
    try publisher.publish(bytes);
    return result;
}
