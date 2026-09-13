const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const header: db.segment.Header = .{
    .segment_id = 1,
    .generation = 1,
    .region = .{ .dimension = 0, .x = 0, .z = 0 },
};
const metadata: db.manifest.Manifest = .{
    .generation = 1,
    .region = header.region,
    .segments = &.{1},
};

fn item(id: u64) db.entry.Entry {
    return .{
        .header = .{ .kind = .put, .batch_id = id, .stored_len = 5, .raw_len = 5 },
        .key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .metadata },
        .value = "saved",
    };
}

const Device = struct {
    bytes: []u8,
    used: usize = 0,
    fail_read: bool = false,
    fail_sync: bool = false,
    writes: usize = 0,
    syncs: usize = 0,

    pub fn length(self: *Device) !u64 {
        return self.used;
    }

    pub fn readExact(self: *Device, output: []u8, offset: u64) !void {
        if (self.fail_read) return error.InputOutput;
        if (offset > self.used or output.len > self.used - offset) return error.UnexpectedEndOfFile;

        const start: usize = @intCast(offset);
        @memcpy(output, self.bytes[start..][0..output.len]);
    }

    pub fn writeAll(self: *Device, input: []const u8, offset: u64) !void {
        const start: usize = @intCast(offset);
        @memcpy(self.bytes[start..][0..input.len], input);
        self.used = @max(self.used, start + input.len);
        self.writes += 1;
    }

    pub fn sync(self: *Device) !void {
        self.syncs += 1;
        if (self.fail_sync) return error.InputOutput;
    }
};

fn populate(device: *Device, batches: usize) !void {
    var writer = try db.segment_writer.Writer(*Device).create(device, header, device.bytes.len, 0);
    var scratch: [256]u8 = undefined;

    for (1..batches + 1) |id| {
        _ = try writer.append(.{ .entries = &.{item(id)} }, &scratch, .buffered);
    }
}

test "file recovery matches memory recovery at every cut" {
    var bytes: [1024]u8 = undefined;
    var device: Device = .{ .bytes = &bytes };
    try populate(&device, 2);
    const end = device.used;
    var scratch: [256]u8 = undefined;

    for (48..end + 1) |cut| {
        device.used = cut;
        var memory = try db.recovery.Scanner.init(bytes[0..cut], header, .active, 0);
        var file = try db.file_recovery.Scanner(*Device).init(&device, header, .active, 0, bytes.len);

        while (try memory.next()) |expected| {
            const actual = (try file.next(&scratch)).?;
            try testing.expectEqualDeep(expected, actual);
        }

        try testing.expectEqual(null, try file.next(&scratch));
        try testing.expectEqual(memory.offset, file.offset);
        try testing.expectEqual(memory.has_tail, file.has_tail);
    }
}

test "small buffers can be retried without advancing" {
    var bytes: [1024]u8 = undefined;
    var device: Device = .{ .bytes = &bytes };
    try populate(&device, 1);
    var file = try db.file_recovery.Scanner(*Device).init(&device, header, .sealed, 0, bytes.len);
    var scratch: [256]u8 = undefined;

    try testing.expectError(error.BufferTooSmall, file.next(scratch[0..64]));
    try testing.expectEqual(@as(usize, 48), file.offset);
    try testing.expectEqual(@as(u64, 1), (try file.next(&scratch)).?.id);
    try testing.expectError(error.SegmentTooLarge, db.file_recovery.Scanner(*Device).init(&device, header, .active, 0, device.used - 1));
}

test "file errors and corruption are not partial tails" {
    var bytes: [1024]u8 = undefined;
    var device: Device = .{ .bytes = &bytes };
    try populate(&device, 1);
    var file = try db.file_recovery.Scanner(*Device).init(&device, header, .active, 0, bytes.len);
    var scratch: [256]u8 = undefined;

    device.fail_read = true;
    try testing.expectError(error.InputOutput, file.next(&scratch));
    device.fail_read = false;
    bytes[48 + db.record.encoded_len] ^= 1;
    try testing.expectError(error.ChecksumMismatch, file.next(&scratch));
    try testing.expectEqual(@as(usize, 48), file.offset);
    try testing.expect(!file.has_tail);
}

test "reopen refuses partial tails without changing the file" {
    var bytes: [1024]u8 = undefined;
    var device: Device = .{ .bytes = &bytes };
    try populate(&device, 2);
    device.used -= 1;
    const writes = device.writes;
    const syncs = device.syncs;
    const before = bytes;
    var scratch: [256]u8 = undefined;

    try testing.expectError(error.NeedsRecovery, db.segment_writer.Writer(*Device).reopen(&device, header, bytes.len, 0, &scratch));
    try testing.expectEqual(writes, device.writes);
    try testing.expectEqual(syncs, device.syncs);
    try testing.expectEqualSlices(u8, before[0..device.used], bytes[0..device.used]);

    var sealed = try db.file_recovery.Scanner(*Device).init(&device, header, .sealed, 0, bytes.len);
    _ = (try sealed.next(&scratch)).?;
    try testing.expectError(error.IncompleteBatch, sealed.next(&scratch));
}

test "reopen requires a successful sync" {
    var bytes: [1024]u8 = undefined;
    var device: Device = .{ .bytes = &bytes };
    try populate(&device, 1);
    device.fail_sync = true;
    var scratch: [256]u8 = undefined;

    try testing.expectError(error.InputOutput, db.segment_writer.Writer(*Device).reopen(&device, header, bytes.len, 0, &scratch));
}

fn rebuildFiles(allocator: std.mem.Allocator) !void {
    var bytes: [4096]u8 = undefined;
    var device: Device = .{ .bytes = &bytes };
    try populate(&device, 10);
    var scratch: [256]u8 = undefined;
    var index = try db.index.rebuildFiles(allocator, metadata, &[_]*Device{&device}, 1, &scratch, bytes.len);
    defer index.deinit();

    try testing.expect(device.used > scratch.len);
    try testing.expectEqual(@as(u64, 10), index.last_batch_id);
    try testing.expectEqualStrings("saved", (try index.read(item(1).key, &device, &scratch)).?);
}

test "file index rebuild stays bounded and cleans up on failure" {
    try testing.checkAllAllocationFailures(testing.allocator, rebuildFiles, .{});
}

test "reopen append and read through the index" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch: [256]u8 = undefined;

    {
        const handle = try tmp.dir.createFile(io, "segment", .{ .read = true, .exclusive = true });
        defer handle.close(io);
        const file: db.storage.File = .{ .handle = handle, .io = io };
        var writer = try db.segment_writer.Writer(db.storage.File).create(file, header, 4096, 0);
        _ = try writer.append(.{ .entries = &.{item(1)} }, &scratch, .sync);
    }

    const handle = try tmp.dir.openFile(io, "segment", .{ .mode = .read_write });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    var writer = try db.segment_writer.Writer(db.storage.File).reopen(file, header, 4096, 0, &scratch);
    try testing.expectEqual(@as(u64, 1), writer.last_batch_id);
    _ = try writer.append(.{ .entries = &.{item(2)} }, &scratch, .sync);

    var index = try db.index.rebuildFiles(testing.allocator, metadata, &[_]db.storage.File{file}, 1, &scratch, 4096);
    defer index.deinit();
    try testing.expectEqual(@as(u64, 2), index.last_batch_id);
    try testing.expectEqualStrings("saved", (try index.read(item(1).key, file, &scratch)).?);
}
