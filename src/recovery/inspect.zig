const std = @import("std");

const Region = @import("../format/key.zig").Region;
const manifest = @import("../format/manifest.zig");
const File = @import("../io/file.zig").File;
const Directory = @import("../storage/directory.zig").Directory;
const files = @import("../storage/files.zig");

const Scanner = @import("file_scan.zig").Scanner(File);

pub const Options = struct {
    max_segments: usize = 64,
    max_segment_size: u64 = 256 * 1024 * 1024,
    max_directory_entries: usize = 8192,
};

pub const Orphan = struct {
    generation: u64,
    id: u64,
};

pub const Report = struct {
    generation: ?u64 = null,
    region: ?Region = null,
    segment_count: usize = 0,
    committed_batches: u64 = 0,
    last_batch_id: u64 = 0,
    active_offset: u64 = 0,
    has_tail: bool = false,
    temporary_manifest: bool = false,
    unknown_entries: usize = 0,
    orphans: []const Orphan = &.{},
};

/// Scratch holds one batch plus its segment header. Orphans use the supplied buffer.
pub fn inspect(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options, scratch: []u8, orphans: []Orphan) !Report {
    if (options.max_segments == 0 or options.max_segments > manifest.max_segments) return error.InvalidOptions;

    var directory = try Directory.init(dir, io);
    defer directory.deinit();
    var report: Report = .{};
    const ids = try allocator.alloc(u64, options.max_segments);
    defer allocator.free(ids);
    var segments: []const u64 = &.{};

    const handle = files.openManifest(directory.dir, io) catch |err| switch (err) {
        error.MissingManifest => null,
        else => return err,
    };
    if (handle) |opened| {
        defer opened.close(io);
        const file: File = .{ .handle = opened, .io = io };
        const length = try file.length();
        if (length > manifest.max_encoded_len) return error.ManifestTooLarge;

        const bytes = try allocator.alloc(u8, @intCast(length));
        defer allocator.free(bytes);
        try file.readExact(bytes, 0);
        const metadata = try manifest.decode(bytes, ids);
        segments = metadata.segments;
        report.generation = metadata.generation;
        report.region = metadata.region;
        report.segment_count = segments.len;

        for (segments, 0..) |id, position| {
            const segment_file = try files.openSegment(directory.dir, io, metadata.generation, id, false);
            defer segment_file.close(io);
            var scanner = try Scanner.init(.{ .handle = segment_file, .io = io }, .{
                .generation = metadata.generation,
                .segment_id = id,
                .region = metadata.region,
            }, if (position == segments.len - 1) .active else .sealed, report.last_batch_id, options.max_segment_size);

            while (try scanner.next(scratch)) |_| {
                report.committed_batches = try std.math.add(u64, report.committed_batches, 1);
            }
            report.last_batch_id = scanner.last_batch_id;
            report.active_offset = scanner.offset;
            report.has_tail = scanner.has_tail;
        }
    }

    var iterator = directory.dir.iterate();
    var count: usize = 0;
    var orphan_count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (count == options.max_directory_entries) return error.TooManyDirectoryEntries;
        count += 1;
        if (std.mem.eql(u8, entry.name, "MANIFEST")) continue;
        if (std.mem.eql(u8, entry.name, "MANIFEST.tmp")) {
            report.temporary_manifest = true;
            continue;
        }
        const candidate = parseName(entry.name) orelse {
            report.unknown_entries += 1;
            continue;
        };
        if (report.generation == candidate.generation and std.mem.indexOfScalar(u64, segments, candidate.id) != null) continue;
        if (orphan_count == orphans.len) return error.BufferTooSmall;
        orphans[orphan_count] = candidate;
        orphan_count += 1;
    }
    report.orphans = orphans[0..orphan_count];
    return report;
}

fn parseName(name: []const u8) ?Orphan {
    if (name.len != 41 or name[16] != '-' or !std.mem.eql(u8, name[33..], ".segment")) return null;
    for (name[0..33], 0..) |byte, i| {
        if (i == 16) continue;
        if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return null;
    }
    const generation = std.fmt.parseInt(u64, name[0..16], 16) catch return null;
    const id = std.fmt.parseInt(u64, name[17..33], 16) catch return null;
    if (generation == 0 or id == 0) return null;
    return .{ .generation = generation, .id = id };
}
