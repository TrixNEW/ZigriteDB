const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

test "positional reads and writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const handle = try tmp.dir.createFile(io, "data", .{ .read = true, .exclusive = true });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };

    try file.writeAll("abcdef", 0);
    try file.writeAll("XY", 2);
    try file.sync();
    try testing.expectEqual(@as(u64, 6), try file.length());
    var bytes: [6]u8 = undefined;
    try file.readExact(bytes[0..2], 4);
    try testing.expectEqualStrings("ef", bytes[0..2]);
    try file.readExact(&bytes, 0);
    try testing.expectEqualStrings("abXYef", &bytes);
    try testing.expectError(error.UnexpectedEndOfFile, file.readExact(&bytes, 1));
    try testing.expectError(error.InvalidOffset, file.writeAll("xx", std.math.maxInt(u64)));
}

test "write close reopen and recover" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const header: db.segment.Header = .{
        .segment_id = 1,
        .generation = 1,
        .region = .{ .dimension = 0, .x = 0, .z = 0 },
    };
    const item: db.entry.Entry = .{
        .header = .{ .kind = .put, .batch_id = 1, .stored_len = 5, .raw_len = 5 },
        .key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .metadata },
        .value = "hello",
    };
    var buffer: [256]u8 = undefined;
    const bytes = try (db.WriteBatch{ .entries = &.{item} }).encode(&buffer);
    {
        const handle = try tmp.dir.createFile(io, "segment", .{ .exclusive = true });
        defer handle.close(io);
        const file: db.storage.File = .{ .handle = handle, .io = io };
        try file.writeAll(&(try header.encode()), 0);
        try file.writeAll(bytes, db.segment.encoded_len);
        try file.sync();
    }
    const handle = try tmp.dir.openFile(io, "segment", .{});
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    var loaded: [512]u8 = undefined;
    const len: usize = @intCast(try file.length());
    try file.readExact(loaded[0..len], 0);
    var scanner = try db.recovery.Scanner.init(loaded[0..len], header, .sealed, 0);
    const recovered = (try scanner.next()).?;
    try testing.expectEqualStrings("hello", (try db.entry.decode(recovered.records)).entry.value);
    try testing.expectEqual(null, try scanner.next());
}
