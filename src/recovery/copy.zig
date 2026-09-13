const std = @import("std");

const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");
const File = @import("../io/file.zig").File;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const publication = @import("../storage/publication.zig");
const Scanner = @import("file_scan.zig").Scanner(File);
const shard = @import("../shard/shard.zig");

pub const Options = struct {
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    batch_buffer_size: usize = 1024 * 1024,
};

pub const Result = struct {
    segment_count: usize,
    committed_batches: u64 = 0,
    last_batch_id: u64 = 0,
    omitted_tail_bytes: u64 = 0,
};

/// Copies committed data into an empty directory and preserves the source.
pub fn recoverTo(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, destination: std.Io.Dir, options: Options) !Result {
    try (shard.Options{
        .max_segments = options.max_segments,
        .max_segment_size = options.max_segment_size,
        .batch_buffer_size = options.batch_buffer_size,
    }).validate();

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
    var result: Result = .{ .segment_count = metadata.segments.len };

    for (metadata.segments, 0..) |id, position| {
        const original = try files.openSegment(input.dir, io, metadata.generation, id, false);
        defer original.close(io);
        var scanner = try Scanner.init(.{ .handle = original, .io = io }, .{
            .generation = metadata.generation,
            .segment_id = id,
            .region = metadata.region,
        }, if (position == metadata.segments.len - 1) .active else .sealed, result.last_batch_id, options.max_segment_size);

        const copied = try files.createSegment(output.dir, io, metadata.generation, id);
        defer copied.close(io);
        const target: File = .{ .handle = copied, .io = io };
        try target.writeAll(&(try scanner.header.encode()), 0);
        var offset: usize = segment.encoded_len;

        while (try scanner.next(scratch)) |batch| {
            const size = batch.end_offset - offset;
            try target.writeAll(scratch[segment.encoded_len..][0..size], offset);
            offset = batch.end_offset;
            result.committed_batches = try std.math.add(u64, result.committed_batches, 1);
        }
        try target.sync();
        result.last_batch_id = scanner.last_batch_id;
        result.omitted_tail_bytes = scanner.length - scanner.offset;
    }

    var publisher: publication.Publisher(*Directory) = .{ .backend = &output };
    try publisher.publish(bytes);
    return result;
}
