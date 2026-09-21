const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/shard.zig");
const item = support.item;
const region = support.header.region;
const segment_name = "0000000000000001-0000000000000001.segment";

fn options() !db.shard.Options {
    return .{
        .max_keys = 8,
        .max_segments = 3,
        .max_segment_size = 48 + try (db.WriteBatch{ .entries = &.{item(1, 0, "saved")} }).size(),
        .batch_buffer_size = 256,
    };
}

test "store rejects unsupported platforms" {
    if (db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.UnsupportedPlatform, db.Store.create(testing.allocator, io, tmp.dir, region, try options()));
    try testing.expectError(error.UnsupportedPlatform, db.Store.open(testing.allocator, io, tmp.dir, try options()));
}

test "store rotates automatically and restores data after close" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: [128]u8 = undefined;

    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try options());
        defer store.deinit();
        try testing.expectError(error.DirectoryBusy, db.Store.open(testing.allocator, io, tmp.dir, try options()));
        _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
        _ = try store.write(.{ .entries = &.{item(2, 1, "saved")} });
        _ = try store.write(.{ .entries = &.{item(3, 0, null)} });
        try testing.expectEqual(@as(usize, 3), store.file_count);
        try testing.expectEqualStrings("saved", (try store.get(item(1, 1, "").key, &output)).?);
        try testing.expectEqual(null, try store.get(item(1, 0, "").key, &output));
        try testing.expectError(error.TooManySegments, store.write(.{ .entries = &.{item(4, 2, "saved")} }));
        try store.close();
        try testing.expectError(error.Closed, store.flush());
    }

    var store = try db.Store.open(testing.allocator, io, tmp.dir, try options());
    defer store.deinit();
    try testing.expectEqualStrings("saved", (try store.get(item(1, 1, "").key, &output)).?);
    try testing.expectEqual(null, try store.get(item(1, 0, "").key, &output));
    try store.close();
}

test "create never replaces an existing store" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try options());
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try store.close();

    try testing.expectError(error.DirectoryNotEmpty, db.Store.create(testing.allocator, io, tmp.dir, region, try options()));
    var reopened = try db.Store.open(testing.allocator, io, tmp.dir, try options());
    defer reopened.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try reopened.get(item(1, 0, "").key, &output)).?);
}

test "unfinished publication blocks startup" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try options());
    defer store.deinit();
    try store.close();
    const temporary = try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true });
    temporary.close(io);

    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, try options()));
    try tmp.dir.deleteFile(io, "MANIFEST.tmp");
    try tmp.dir.deleteFile(io, segment_name);
    try testing.expectError(error.MissingSegment, db.Store.open(testing.allocator, io, tmp.dir, try options()));
}

test "manifest and segment symlinks are rejected" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try options());
    defer store.deinit();
    try store.close();

    for ([_][]const u8{ "MANIFEST", segment_name }) |name| {
        try tmp.dir.rename(name, tmp.dir, "backup", io);
        try tmp.dir.symLink(io, "backup", name, .{});
        try testing.expectError(error.SymlinkNotAllowed, db.Store.open(testing.allocator, io, tmp.dir, try options()));
        try tmp.dir.deleteFile(io, name);
        try tmp.dir.rename("backup", tmp.dir, name, io);
    }
}

test "manifest size and file type are checked" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "MANIFEST", .default_dir);
    try testing.expectError(error.NotRegularFile, db.Store.open(testing.allocator, io, tmp.dir, try options()));

    var other = testing.tmpDir(.{});
    defer other.cleanup();
    const file = try other.dir.createFile(io, "MANIFEST", .{ .exclusive = true });
    try file.setLength(io, db.manifest.max_encoded_len + 1);
    file.close(io);
    try testing.expectError(error.ManifestTooLarge, db.Store.open(testing.allocator, io, other.dir, try options()));
}

fn openWithAllocator(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var store = try db.Store.open(allocator, io, dir, try options());
    defer store.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try store.get(item(1, 0, "").key, &output)).?);
}

test "failed opens release allocations and locks" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(testing.allocator, io, tmp.dir, region, try options());
    defer store.deinit();
    _ = try store.write(.{ .entries = &.{item(1, 0, "saved")} });
    try store.close();

    try testing.checkAllAllocationFailures(testing.allocator, openWithAllocator, .{tmp.dir});
}

fn createWithAllocator(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(allocator, io, tmp.dir, region, try options());
    defer store.deinit();
    try store.close();
}

test "failed creates release resources" {
    if (!db.directory.supported) return error.SkipZigTest;

    try testing.checkAllAllocationFailures(testing.allocator, createWithAllocator, .{});
}

fn getManyOversizedAllocationFailure(allocator: std.mem.Allocator) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try db.Store.create(allocator, io, tmp.dir, region, .{ .max_segment_size = 65536, .batch_buffer_size = 16384 });
    defer store.deinit();

    var big_value: [8200]u8 = undefined;
    @memset(&big_value, 'z');
    _ = try store.write(.{ .entries = &.{item(1, 0, &big_value)} });

    var out: [8200]u8 = undefined;
    const requests = [_]db.ReadRequest{.{ .key = item(1, 0, "").key, .output = &out }};
    var results: [1]db.ReadResult = undefined;
    try store.getMany(&requests, &results);
    try testing.expectEqual(db.ReadStatus.ok, results[0].status);
}

test "getMany releases its pin even when the oversized-record heap fallback fails" {
    if (!db.directory.supported) return error.SkipZigTest;

    try testing.checkAllAllocationFailures(testing.allocator, getManyOversizedAllocationFailure, .{});
}
