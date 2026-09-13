const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const support = @import("support/shard.zig");
const name = "0000000000000001-0000000000000001.segment";

test "inspection preserves partial tails and publication leftovers" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch: [512]u8 = undefined;
    var orphans: [2]db.inspection.Orphan = undefined;
    var store = try db.Store.create(testing.allocator, io, tmp.dir, support.header.region, .{ .max_segment_size = 256, .batch_buffer_size = 256 });
    defer store.deinit();
    try testing.expectError(error.DirectoryBusy, db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans));
    _ = try store.write(.{ .entries = &.{support.item(1, 0, "saved")} });
    _ = try store.write(.{ .entries = &.{support.item(2, 1, "saved")} });
    try store.close();
    const clean = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(@as(u64, 2), clean.committed_batches);
    try testing.expect(!clean.has_tail);
    try testing.expectEqual(@as(usize, 2), clean.segment_count);

    const handle = try tmp.dir.openFile(io, "0000000000000001-0000000000000002.segment", .{ .mode = .read_write });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    try file.writeAll("ZG", clean.active_offset);
    const temporary = try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true });
    temporary.close(io);
    const orphan = try tmp.dir.createFile(io, "0000000000000002-0000000000000001.segment", .{ .exclusive = true });
    orphan.close(io);

    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expect(report.has_tail and report.temporary_manifest);
    try testing.expectEqual(clean.active_offset, report.active_offset);
    try testing.expectEqual(@as(u64, 2), report.last_batch_id);
    try testing.expectEqual(@as(usize, 1), report.orphans.len);
    try testing.expectEqual(@as(u64, 2), report.orphans[0].generation);
    try testing.expectEqual(clean.active_offset + 2, try file.length());
    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, .{}));
    try file.writeAll("bad!", 48);
    try testing.expectError(error.InvalidMagic, db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans));
}

test "inspection bounds orphan output without a manifest" {
    if (!db.directory.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch: [512]u8 = undefined;
    var orphans: [1]db.inspection.Orphan = undefined;
    const file = try tmp.dir.createFile(io, name, .{ .exclusive = true });
    file.close(io);
    try testing.expectError(error.BufferTooSmall, db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &.{}));
    try testing.expectError(error.TooManyDirectoryEntries, db.inspection.inspect(testing.allocator, io, tmp.dir, .{ .max_directory_entries = 0 }, &scratch, &orphans));
    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(null, report.generation);
    try testing.expectEqual(@as(usize, 1), report.orphans.len);
}
