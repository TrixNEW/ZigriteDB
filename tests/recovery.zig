const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const support = @import("support/region.zig");
const key = support.key;
const put = support.put;
const batch = support.batch;

const header: db.segment.Header = .{ .segment_id = 1, .generation = 1, .region = support.region, .salt = 42 };

fn frameAt(buffer: []u8, kind: db.frame.Kind, id: u64, x: u10) ![]u8 {
    var builder: db.frame.Builder = .init(buffer);
    try builder.add(x, 0x2c80, "saved", null, 0);
    try builder.add(x + 1, 0x2c80, null, null, 0);
    return builder.finish(kind, id, header.salt);
}

fn segmentWith(bytes: []u8, frames: []const struct { kind: db.frame.Kind, id: u64 }, ends: []usize) !usize {
    @memcpy(bytes[0..db.segment.encoded_len], &(try header.encode()));
    var at: usize = db.segment.encoded_len;
    for (frames, ends) |f, *end| {
        at += (try frameAt(bytes[at..], f.kind, f.id, 3)).len;
        end.* = at;
    }
    return at;
}

test "the scanner returns committed frames in order" {
    var bytes: [1024]u8 = undefined;
    var ends: [2]usize = undefined;
    const end = try segmentWith(&bytes, &.{ .{ .kind = .batch, .id = 1 }, .{ .kind = .batch, .id = 2 } }, &ends);
    var scanner = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{});
    try testing.expectEqual(@as(u64, 1), (try scanner.next()).?.header.batch_id);
    const second = (try scanner.next()).?;
    try testing.expectEqual(@as(u64, 2), second.header.batch_id);
    try testing.expectEqual(@as(u64, ends[0]), second.offset);
    try testing.expectEqual(end, scanner.offset);
    try testing.expectEqual(null, try scanner.next());
}

test "a cut or damaged frame is a tail when active and an error when sealed" {
    var bytes: [1024]u8 = undefined;
    var ends: [2]usize = undefined;
    const end = try segmentWith(&bytes, &.{ .{ .kind = .batch, .id = 1 }, .{ .kind = .batch, .id = 2 } }, &ends);
    for (ends[0] + 1..end) |cut| {
        var active = try db.recovery.Scanner.init(bytes[0..cut], header, .active, .{});
        _ = (try active.next()).?;
        try testing.expectEqual(null, try active.next());
        try testing.expect(active.has_tail);
        try testing.expectEqual(ends[0], active.offset);

        var sealed = try db.recovery.Scanner.init(bytes[0..cut], header, .sealed, .{});
        _ = (try sealed.next()).?;
        try testing.expectError(error.IncompleteBatch, sealed.next());
    }
    for (ends[0]..end) |i| {
        bytes[i] ^= 0x10;
        defer bytes[i] ^= 0x10;
        var active = try db.recovery.Scanner.init(bytes[0..end], header, .active, .{});
        _ = (try active.next()).?;
        try testing.expectEqual(null, try active.next());
        try testing.expect(active.has_tail);
        var sealed = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{});
        _ = (try sealed.next()).?;
        try testing.expect(std.meta.isError(sealed.next()));
    }
}

test "frames from another region's salt are never accepted" {
    var bytes: [1024]u8 = undefined;
    var ends: [1]usize = undefined;
    const end = try segmentWith(&bytes, &.{.{ .kind = .batch, .id = 1 }}, &ends);
    var other = header;
    other.salt = 7;
    @memcpy(bytes[0..db.segment.encoded_len], &(try other.encode()));
    var scanner = try db.recovery.Scanner.init(bytes[0..end], other, .active, .{});
    try testing.expectEqual(null, try scanner.next());
    try testing.expect(scanner.has_tail);
}

test "batch order and base frames are enforced" {
    var bytes: [2048]u8 = undefined;
    var ends: [3]usize = undefined;
    var end = try segmentWith(&bytes, &.{ .{ .kind = .base, .id = 5 }, .{ .kind = .base, .id = 5 }, .{ .kind = .batch, .id = 6 } }, &ends);
    var scanner = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{ .last_batch_id = 5 });
    for (0..3) |_| _ = (try scanner.next()).?;
    try testing.expectEqual(@as(u64, 6), scanner.order.last_batch_id);

    var wrong_base = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{ .last_batch_id = 4 });
    try testing.expectError(error.BatchOrder, wrong_base.next());

    end = try segmentWith(&bytes, &.{ .{ .kind = .batch, .id = 6 }, .{ .kind = .base, .id = 6 } }, ends[0..2]);
    var late_base = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{ .last_batch_id = 5 });
    _ = (try late_base.next()).?;
    try testing.expectError(error.BatchOrder, late_base.next());

    end = try segmentWith(&bytes, &.{ .{ .kind = .batch, .id = 3 }, .{ .kind = .batch, .id = 3 } }, ends[0..2]);
    var repeated = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{});
    _ = (try repeated.next()).?;
    try testing.expectError(error.BatchOrder, repeated.next());
    var continued = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, .{ .last_batch_id = 3 });
    try testing.expectError(error.BatchOrder, continued.next());
}

test "file scanning matches memory scanning at every cut and window size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [1024]u8 = undefined;
    var ends: [3]usize = undefined;
    const end = try segmentWith(&bytes, &.{ .{ .kind = .batch, .id = 1 }, .{ .kind = .batch, .id = 2 }, .{ .kind = .batch, .id = 3 } }, &ends);
    const handle = try tmp.dir.createFile(io, "segment", .{ .read = true });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    const frame_len = ends[0] - db.segment.encoded_len;

    for (db.segment.encoded_len..end + 1) |cut| {
        try handle.setLength(io, 0);
        try file.writeAll(bytes[0..cut], 0);
        for ([_]usize{ frame_len, frame_len + 7, 4096 }) |window| {
            var memory = try db.recovery.Scanner.init(bytes[0..cut], header, .active, .{});
            var scanner = try db.recovery.FileScanner(db.storage.File).init(file, header, .active, .{}, 1 << 20);
            var scratch: [4096]u8 = undefined;
            while (try memory.next()) |expected| {
                const actual = (try scanner.next(scratch[0..window])).?;
                try testing.expectEqual(expected.offset, actual.offset);
                try testing.expectEqualSlices(u8, expected.bytes, actual.bytes);
            }
            try testing.expectEqual(null, try scanner.next(scratch[0..window]));
            try testing.expectEqual(memory.has_tail, scanner.has_tail);
            try testing.expectEqual(@as(u64, memory.offset), scanner.offset);
        }
    }
    var scratch: [16]u8 = undefined;
    var scanner = try db.recovery.FileScanner(db.storage.File).init(file, header, .active, .{}, 1 << 20);
    try testing.expectError(error.BufferTooSmall, scanner.next(&scratch));
    try testing.expectError(error.SegmentTooLarge, db.recovery.FileScanner(db.storage.File).init(file, header, .active, .{}, 64));
}

fn populate(dir: std.Io.Dir) !void {
    var store = try db.Store.create(testing.allocator, io, dir, support.region, .{
        .max_segment_size = try support.segmentFor(&.{batch(1, &.{put(0, "saved")})}),
        .batch_buffer_size = 256,
    });
    defer store.deinit();
    _ = try store.write(batch(1, &.{put(0, "saved")}));
    _ = try store.write(batch(2, &.{put(0, null)}));
    try store.close();
}

const active_name = "0000000000000001-0000000000000002.segment";

test "recovery copies committed frames and leaves the source intact" {
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    var destination = testing.tmpDir(.{});
    defer destination.cleanup();
    try populate(source.dir);

    const file = try support.openFile(source.dir, active_name);
    defer file.handle.close(io);
    const length = try file.length();
    try file.writeAll("ZG", length);
    (try source.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true })).close(io);
    (try source.dir.createFile(io, "0000000000000001-0000000000000003.segment", .{ .exclusive = true })).close(io);

    var stats: db.Stats = .{};
    const result = try db.recovery_copy.recoverTo(testing.allocator, io, source.dir, destination.dir, .{ .stats = &stats });
    try testing.expectEqual(@as(u64, 1), stats.recovery_attempts.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), stats.recovery_errors.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), result.segment_count);
    try testing.expectEqual(@as(u64, 2), result.committed_batches);
    try testing.expectEqual(@as(u64, 2), result.last_batch_id);
    try testing.expectEqual(@as(u64, 2), result.omitted_tail_bytes);
    try testing.expectEqual(length + 2, try file.length());
    _ = try source.dir.statFile(io, "MANIFEST.tmp", .{});
    try testing.expectError(error.FileNotFound, destination.dir.statFile(io, "MANIFEST.tmp", .{}));

    var recovered = try db.Store.open(testing.allocator, io, destination.dir, .{});
    defer recovered.deinit();
    var value: [128]u8 = undefined;
    try testing.expectEqual(null, try recovered.get(key(0), &value));
    _ = try recovered.write(batch(3, &.{put(1, "new")}));
    try recovered.close();
    var reopened = try db.Store.open(testing.allocator, io, destination.dir, .{});
    defer reopened.deinit();
    try testing.expectEqualStrings("new", (try reopened.get(key(1), &value)).?);
}

test "recovery never publishes corrupt sealed data or replaces a destination" {
    var source = testing.tmpDir(.{});
    defer source.cleanup();
    var destination = testing.tmpDir(.{ .iterate = true });
    defer destination.cleanup();
    try populate(source.dir);
    try testing.expectError(error.DirectoryBusy, db.recovery_copy.recoverTo(testing.allocator, io, source.dir, source.dir, .{}));
    (try destination.dir.createFile(io, "existing", .{})).close(io);
    try testing.expectError(error.DirectoryNotEmpty, db.recovery_copy.recoverTo(testing.allocator, io, source.dir, destination.dir, .{}));
    try destination.dir.deleteFile(io, "existing");

    const sealed = try support.openFile(source.dir, support.segment_name);
    defer sealed.handle.close(io);
    try sealed.writeAll("X", db.segment.encoded_len + db.frame.header_len + db.record.header_len);
    try testing.expectError(error.ChecksumMismatch, db.recovery_copy.recoverTo(testing.allocator, io, source.dir, destination.dir, .{}));
    var iterator = destination.dir.iterate();
    try testing.expectEqual(null, try iterator.next(io));
}

test "inspection reports tails and publication leftovers without changing anything" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch: [512]u8 = undefined;
    var orphans: [2]db.inspection.Orphan = undefined;
    {
        var store = try db.Store.create(testing.allocator, io, tmp.dir, support.region, .{ .max_segment_size = try support.segmentFor(&.{batch(1, &.{put(0, "saved")})}), .batch_buffer_size = 256 });
        defer store.deinit();
        try testing.expectError(error.DirectoryBusy, db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans));
        _ = try store.write(batch(1, &.{put(0, "saved")}));
        _ = try store.write(batch(2, &.{put(1, "saved")}));
        try store.close();
    }
    const clean = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(@as(u64, 2), clean.committed_batches);
    try testing.expect(!clean.has_tail);
    try testing.expectEqual(@as(usize, 2), clean.segment_count);

    const file = try support.openFile(tmp.dir, active_name);
    defer file.handle.close(io);
    try file.writeAll("ZG", clean.active_offset);
    (try tmp.dir.createFile(io, "MANIFEST.tmp", .{ .exclusive = true })).close(io);
    (try tmp.dir.createFile(io, "0000000000000002-0000000000000001.segment", .{ .exclusive = true })).close(io);

    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expect(report.has_tail and report.temporary_manifest);
    try testing.expectEqual(clean.active_offset, report.active_offset);
    try testing.expectEqual(@as(u64, 2), report.last_batch_id);
    try testing.expectEqual(@as(usize, 1), report.orphans.len);
    try testing.expectEqual(@as(u64, 2), report.orphans[0].generation);
    try testing.expectEqual(clean.active_offset + 2, try file.length());
    try testing.expectError(error.NeedsRecovery, db.Store.open(testing.allocator, io, tmp.dir, .{}));
    try file.writeAll("bad!", 0);
    try testing.expectError(error.InvalidMagic, db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans));
}

test "inspection bounds orphan output without a manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch: [512]u8 = undefined;
    var orphans: [1]db.inspection.Orphan = undefined;
    (try tmp.dir.createFile(io, support.segment_name, .{ .exclusive = true })).close(io);
    try testing.expectError(error.BufferTooSmall, db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &.{}));
    try testing.expectError(error.TooManyDirectoryEntries, db.inspection.inspect(testing.allocator, io, tmp.dir, .{ .max_directory_entries = 0 }, &scratch, &orphans));
    const report = try db.inspection.inspect(testing.allocator, io, tmp.dir, .{}, &scratch, &orphans);
    try testing.expectEqual(null, report.generation);
    try testing.expectEqual(@as(usize, 1), report.orphans.len);
}
