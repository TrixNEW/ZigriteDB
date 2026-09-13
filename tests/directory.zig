const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const header: db.segment.Header = .{
    .segment_id = 1,
    .generation = 1,
    .region = .{ .dimension = 0, .x = 0, .z = 0 },
};

fn encode(ids: []const u64, buffer: []u8) ![]u8 {
    return (db.manifest.Manifest{
        .generation = 1,
        .region = header.region,
        .segments = ids,
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

test "rotate real segments and reopen the published manifest" {
    if (!db.directory.supported) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory = try db.directory.Directory.init(tmp.dir, io);
    defer directory.deinit();
    var publisher: db.publication.Publisher(*db.directory.Directory) = .{ .backend = &directory };
    const first = try tmp.dir.createFile(io, "1.segment", .{ .read = true, .exclusive = true });
    defer first.close(io);
    const second = try tmp.dir.createFile(io, "2.segment", .{ .read = true, .exclusive = true });
    defer second.close(io);
    const devices = [_]db.storage.File{
        .{ .handle = first, .io = io },
        .{ .handle = second, .io = io },
    };
    const options: db.shard.Options = .{ .batch_buffer_size = 256, .max_segment_size = 4096 };
    const item: db.entry.Entry = .{
        .header = .{ .kind = .put, .batch_id = 1, .stored_len = 5, .raw_len = 5 },
        .key = .{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .metadata },
        .value = "saved",
    };
    var buffer: [128]u8 = undefined;
    {
        var shard = try db.shard.Shard(db.storage.File).create(testing.allocator, io, devices[0], header, options);
        defer shard.deinit();
        try publisher.publish(try encode(&.{1}, &buffer));
        _ = try shard.write(.{ .entries = &.{item} });
        try shard.rotate(devices[1], 2, &publisher);
        try shard.close();
    }

    var ids: [2]u64 = undefined;
    const metadata = try db.manifest.decode(try readManifest(tmp.dir, &buffer), &ids);
    var shard = try db.shard.Shard(db.storage.File).openSegments(testing.allocator, io, &devices, metadata, options);
    defer shard.deinit();
    try testing.expectEqualStrings("saved", (try shard.get(item.key, &buffer)).?);
    try shard.close();
}
