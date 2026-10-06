const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const region: db.Region = .{ .dimension = 0, .x = 0, .z = 0 };

fn encode(ids: []const u64, buffer: []u8) ![]u8 {
    return (db.manifest.Manifest{
        .generation = 1,
        .region = region,
        .segments = ids,
        .salt = 1,
    }).encode(buffer);
}

fn readManifest(dir: std.Io.Dir, buffer: []u8) ![]u8 {
    const handle = try dir.openFile(io, "MANIFEST", .{});
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    const len: usize = @intCast(try file.length());
    if (len > buffer.len) return error.BufferTooSmall;
    try file.readExact(buffer[0..len], 0);
    return buffer[0..len];
}

test "unsupported platforms reject the directory backend" {
    if (db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.UnsupportedPlatform, db.directory.Directory.init(tmp.dir, io));
}

test "manifest replacement survives closing and reopening" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var expected: [128]u8 = undefined;
    const bytes = try encode(&.{ 1, 2 }, &expected);

    {
        var directory = try db.directory.Directory.init(tmp.dir, io);
        defer directory.deinit();
        var publisher: db.publication.Publisher(*db.directory.Directory) = .{ .backend = &directory };
        var initial: [128]u8 = undefined;
        try publisher.publish(try encode(&.{1}, &initial));
        try publisher.publish(bytes);
    }

    var reopened = try db.directory.Directory.init(tmp.dir, io);
    defer reopened.deinit();
    var actual: [128]u8 = undefined;
    try testing.expectEqualSlices(u8, bytes, try readManifest(tmp.dir, &actual));
}

test "only one publisher can hold the directory" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try db.directory.Directory.init(tmp.dir, io);
    defer directory.deinit();
    try testing.expectError(error.DirectoryBusy, db.directory.Directory.init(tmp.dir, io));
    directory.deinit();
    var next = try db.directory.Directory.init(tmp.dir, io);
    defer next.deinit();
}

test "unfinished publication keeps the previous manifest" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [128]u8 = undefined;
    var expected: [128]u8 = undefined;
    const original = try encode(&.{1}, &expected);

    {
        var directory = try db.directory.Directory.init(tmp.dir, io);
        defer directory.deinit();
        var publisher: db.publication.Publisher(*db.directory.Directory) = .{ .backend = &directory };
        try publisher.publish(original);
        try directory.writeTemporary(try encode(&.{ 1, 2 }, &buffer));
        try directory.syncTemporary();
    }

    var directory = try db.directory.Directory.init(tmp.dir, io);
    defer directory.deinit();
    var publisher: db.publication.Publisher(*db.directory.Directory) = .{ .backend = &directory };
    try testing.expectError(error.PathAlreadyExists, publisher.publish(try encode(&.{ 1, 3 }, &buffer)));
    try testing.expectEqualSlices(u8, original, try readManifest(tmp.dir, &buffer));
}

test "bad manifests never create temporary files" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try db.directory.Directory.init(tmp.dir, io);
    defer directory.deinit();
    var publisher: db.publication.Publisher(*db.directory.Directory) = .{ .backend = &directory };
    try testing.expectError(error.TruncatedManifest, publisher.publish("bad"));
    try testing.expectError(error.InvalidPublicationState, directory.replaceManifest());
    var buffer: [128]u8 = undefined;
    try publisher.publish(try encode(&.{1}, &buffer));
}
