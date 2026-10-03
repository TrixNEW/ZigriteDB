const std = @import("std");
const db = @import("zigritedb");

const usage =
    \\usage: zigrite <command> ...
    \\
    \\  migrate <format-1 world> <new world>   convert a world written before format 2
    \\  verify <world>                         check every frame of every region
    \\  compact <world>                        compact every region
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (args.len < 2) return fail(out, usage);
    const command = args[1];
    const cwd = std.Io.Dir.cwd();

    if (std.mem.eql(u8, command, "migrate") and args.len == 4) {
        const result = try db.migrate.migrate(allocator, io, cwd, args[2], args[3]);
        try out.print("migrated {} regions, {} batches, {} records", .{ result.regions, result.batches, result.records });
        if (result.omitted_tail_bytes != 0) try out.print("; left out {} bytes of torn tails", .{result.omitted_tail_bytes});
        try out.writeAll("\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "verify") and args.len == 3) return verify(allocator, io, cwd, args[2], out);
    if (std.mem.eql(u8, command, "compact") and args.len == 3) {
        const dir = try cwd.openDir(io, args[2], .{ .follow_symlinks = false });
        defer dir.close(io);
        var world = try db.World.open(allocator, io, dir, .{});
        defer world.deinit();
        const regions = try world.regions(allocator);
        defer allocator.free(regions);
        var before: u64 = 0;
        var after: u64 = 0;
        for (regions) |region| {
            const result = (try world.compact(region)).?;
            before += result.source_bytes;
            after += result.output_bytes;
        }
        try world.close();
        try out.print("compacted {} regions: read {} bytes, wrote {}\n", .{ regions.len, before, after });
        return 0;
    }
    return fail(out, usage);
}

fn fail(out: *std.Io.Writer, message: []const u8) !u8 {
    try out.writeAll(message);
    return 2;
}

/// Read-only full check that ignores INDEX files.
fn verify(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8, out: *std.Io.Writer) !u8 {
    const dir = try cwd.openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    const scratch = try allocator.alloc(u8, 64 * 1024 * 1024 + 1024 * 1024);
    defer allocator.free(scratch);
    var orphans: [64]db.inspection.Orphan = undefined;
    var regions: usize = 0;
    var batches: u64 = 0;
    var problems: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory or db.World.parseRegionName(entry.name) == null) continue;
        regions += 1;
        const region_dir = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
        defer region_dir.close(io);
        const report = db.inspection.inspect(allocator, io, region_dir, .{}, scratch, &orphans) catch |err| {
            try out.print("{s}: {t}\n", .{ entry.name, err });
            problems += 1;
            continue;
        };
        batches += report.committed_batches;
        if (report.has_tail or report.temporary_manifest or report.orphans.len != 0) {
            try out.print("{s}: tail={} unfinished publication={} orphans={}\n", .{ entry.name, report.has_tail, report.temporary_manifest, report.orphans.len });
            problems += 1;
        }
    }
    try out.print("{} regions, {} committed batches, {} with problems\n", .{ regions, batches, problems });
    return if (problems == 0) 0 else 1;
}
