const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const header: db.segment.Header = .{
    .segment_id = 1,
    .generation = 1,
    .region = .{ .dimension = 0, .x = 0, .z = 0 },
};
const item: db.entry.Entry = .{
    .header = .{ .kind = .put, .batch_id = 1 },
    .key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .metadata },
    .value = "",
};
const batch: db.WriteBatch = .{ .entries = &.{item} };

const Device = struct {
    bytes: [512]u8 = undefined,
    used: usize = 0,
    writes: usize = 0,
    syncs: usize = 0,
    fail_write: bool = false,
    fail_sync: bool = false,

    pub fn length(self: *Device) !u64 {
        return self.used;
    }

    pub fn writeAll(self: *Device, bytes: []const u8, offset: u64) !void {
        self.writes += 1;
        const start: usize = @intCast(offset);
        const count = if (self.fail_write) bytes.len / 2 else bytes.len;
        @memcpy(self.bytes[start..][0..count], bytes[0..count]);
        self.used = @max(self.used, start + count);
        if (self.fail_write) return error.NoSpaceLeft;
    }

    pub fn sync(self: *Device) !void {
        self.syncs += 1;
        if (self.fail_sync) return error.InputOutput;
    }
};

test "buffered writes sync on flush" {
    var device: Device = .{};
    var writer = try db.segment_writer.Writer(*Device).create(&device, header, 512, 0);
    var scratch: [256]u8 = undefined;
    const result = try writer.append(batch, &scratch, .buffered);
    try testing.expect(!result.synced);
    try testing.expectEqual(@as(u64, 48), writer.synced_offset);
    try writer.flush();
    try testing.expectEqual(result.end, writer.synced_offset);
    try testing.expectEqual(@as(usize, 2), device.syncs);
    try writer.flush();
    try testing.expectEqual(@as(usize, 2), device.syncs);
}

test "partial write and sync failures stop the writer" {
    for ([_]bool{ false, true }) |fail_sync| {
        var device: Device = .{};
        var writer = try db.segment_writer.Writer(*Device).create(&device, header, 512, 0);
        device.fail_write = !fail_sync;
        device.fail_sync = fail_sync;
        var scratch: [256]u8 = undefined;
        const expected = if (fail_sync) error.InputOutput else error.NoSpaceLeft;
        try testing.expectError(expected, writer.append(batch, &scratch, .sync));
        try testing.expectEqual(@as(u64, 48), writer.offset);
        try testing.expectEqual(@as(u64, 48), writer.synced_offset);
        const writes = device.writes;
        try testing.expectError(error.WriterFailed, writer.append(batch, &scratch, .sync));
        try testing.expectError(error.WriterFailed, writer.flush());
        try testing.expectEqual(writes, device.writes);
    }
}

test "bad input does not write or stop the writer" {
    var device: Device = .{};
    const limit = 48 + try batch.size();
    var writer = try db.segment_writer.Writer(*Device).create(&device, header, limit, 0);
    var scratch: [256]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, writer.append(batch, scratch[0..1], .sync));
    var wrong = item;
    wrong.key.chunk_x = 32;
    try testing.expectError(error.RegionMismatch, writer.append(.{ .entries = &.{wrong} }, &scratch, .sync));
    try testing.expectEqual(@as(usize, 1), device.writes);
    const result = try writer.append(batch, &scratch, .sync);
    try testing.expect(result.synced);
    try testing.expectEqual(limit, result.end);
    try testing.expectError(error.BatchOrder, writer.append(batch, &scratch, .sync));
    wrong = item;
    wrong.header.batch_id = 2;
    try testing.expectError(error.SegmentFull, writer.append(.{ .entries = &.{wrong} }, &scratch, .sync));
    try testing.expect(!writer.failed);
}

test "create never overwrites an existing file" {
    var device: Device = .{ .used = 1 };
    try testing.expectError(error.FileNotEmpty, db.segment_writer.Writer(*Device).create(&device, header, 512, 0));
    try testing.expectEqual(@as(usize, 0), device.writes);
}

test "flush failure stops further appends" {
    var device: Device = .{};
    var writer = try db.segment_writer.Writer(*Device).create(&device, header, 512, 0);
    var scratch: [256]u8 = undefined;
    _ = try writer.append(batch, &scratch, .buffered);
    device.fail_sync = true;
    try testing.expectError(error.InputOutput, writer.flush());
    try testing.expectEqual(@as(u64, 48), writer.synced_offset);
    try testing.expectError(error.WriterFailed, writer.append(batch, &scratch, .buffered));
}

test "synced segment can be reopened and recovered" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const handle = try tmp.dir.createFile(io, "segment", .{ .read = true, .exclusive = true });
        defer handle.close(io);
        const file: db.storage.File = .{ .handle = handle, .io = io };
        var writer = try db.segment_writer.Writer(db.storage.File).create(file, header, 512, 0);
        var scratch: [256]u8 = undefined;
        _ = try writer.append(batch, &scratch, .sync);
    }
    const handle = try tmp.dir.openFile(io, "segment", .{});
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    var bytes: [512]u8 = undefined;
    const len: usize = @intCast(try file.length());
    try file.readExact(bytes[0..len], 0);
    var scan = try db.recovery.Scanner.init(bytes[0..len], header, .sealed, 0);
    try testing.expectEqual(@as(u64, 1), (try scan.next()).?.id);
    try testing.expectEqual(null, try scan.next());
}
