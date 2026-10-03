const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const leveldb = db.leveldb;

fn chunkKey(x: i32, z: i32, dim: i32, tag: u8, y: ?i8, out: *[16]u8) []const u8 {
    return db.bedrock.levelKey(.{ .dimension = dim, .chunk_x = x, .chunk_z = z, .component = @enumFromInt(tag), .subchunk_y = y orelse 0 }, out);
}

const Expected = std.StringArrayHashMapUnmanaged([]const u8);

fn buildWorld(arena: std.mem.Allocator, parent: std.Io.Dir, expected: *Expected) !void {
    try parent.createDir(io, "bedrock", .default_dir);
    const world = try parent.openDir(io, "bedrock", .{});
    defer world.close(io);
    try world.writeFile(io, .{ .sub_path = "level.dat", .data = "level data" });
    try world.writeFile(io, .{ .sub_path = "levelname.txt", .data = "Test" });
    try world.createDir(io, "behavior_packs", .default_dir);
    try world.writeFile(io, .{ .sub_path = "behavior_packs/pack.json", .data = "{}" });
    try world.createDir(io, "db", .default_dir);
    const dir = try world.openDir(io, "db", .{});
    defer dir.close(io);

    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var buffer: [16]u8 = undefined;
    for ([_]i32{ -40, -1, 0, 31, 32, 1000 }) |x| {
        for ([_]i32{ -33, 0, 5 }) |z| {
            for ([_]i32{ 0, 1, 2 }) |dim| {
                try keys.append(arena, try arena.dupe(u8, chunkKey(x, z, dim, 0x2c, null, &buffer)));
                try keys.append(arena, try arena.dupe(u8, chunkKey(x, z, dim, 0x2b, null, &buffer)));
                for ([_]i8{ -4, -1, 0, 7, 19 }) |y| try keys.append(arena, try arena.dupe(u8, chunkKey(x, z, dim, 0x2f, y, &buffer)));
                try keys.append(arena, try arena.dupe(u8, chunkKey(x, z, dim, 0x80, null, &buffer)));
            }
        }
    }
    for ([_][]const u8{ "~local_player", "scoreboard", "BiomeData", "portals", "Overworld", "mobevents", "player_server_abc" }) |name| try keys.append(arena, name);
    try keys.append(arena, "actorprefix" ++ [_]u8{ 0, 0, 0, 1, 0, 0, 0, 7 });
    try keys.append(arena, &[_]u8{ 7, 0, 0, 0, 11, 0, 0, 0 } ++ "PMMPDataVersion");
    // Not Bedrock's layout, so it stays raw.
    try keys.append(arena, &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x2c });
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var writer = try leveldb.Writer.init(arena, io, dir, .zlib_raw);
    var prng = std.Random.DefaultPrng.init(5);
    for (keys.items, 0..) |key, i| {
        const value = try arena.alloc(u8, if (i % 9 == 0) 70_000 else i % 300);
        for (value, 0..) |*b, j| b.* = if (i % 2 == 0) @truncate(j / 50) else prng.random().int(u8);
        try writer.add(key, value);
        try expected.put(arena, key, value);
    }
    try writer.finish();

    const handle = try dir.createFile(io, "000009.log", .{ .read = true });
    defer handle.close(io);
    var log: leveldb.LogWriter = .{ .file = .{ .handle = handle, .io = io } };
    var batch: std.ArrayListUnmanaged(u8) = .empty;
    var header: [12]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], 100, .little);
    std.mem.writeInt(u32, header[8..12], 3, .little);
    try batch.appendSlice(arena, &header);
    const overwritten = keys.items[3];
    const deleted = keys.items[4];
    for ([_]struct { []const u8, ?[]const u8 }{ .{ overwritten, "newer" }, .{ deleted, null }, .{ "fresh_key", "fresh" } }) |change| {
        try batch.append(arena, if (change[1] == null) 0 else 1);
        try batch.append(arena, @intCast(change[0].len));
        try batch.appendSlice(arena, change[0]);
        if (change[1]) |v| {
            try batch.append(arena, @intCast(v.len));
            try batch.appendSlice(arena, v);
        }
    }
    try log.add(batch.items);
    try expected.put(arena, overwritten, "newer");
    _ = expected.orderedRemove(deleted);
    try expected.put(arena, "fresh_key", "fresh");
}

fn expectReads(dir: std.Io.Dir, expected: *Expected) !void {
    var reader = try leveldb.Reader.open(testing.allocator, io, dir);
    defer reader.deinit();
    var count: usize = 0;
    var previous: std.ArrayListUnmanaged(u8) = .empty;
    defer previous.deinit(testing.allocator);
    while (try reader.next()) |item| {
        const key, const value = item;
        if (count != 0) try testing.expect(std.mem.order(u8, previous.items, key) == .lt);
        previous.clearRetainingCapacity();
        try previous.appendSlice(testing.allocator, key);
        try testing.expectEqualSlices(u8, expected.get(key) orelse return error.UnexpectedKey, value);
        count += 1;
    }
    try testing.expectEqual(expected.count(), count);
}

test "import and export keep every key, value and world file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var expected: Expected = .empty;
    try buildWorld(arena_state.allocator(), tmp.dir, &expected);
    {
        const source_db = try tmp.dir.openDir(io, "bedrock/db", .{ .iterate = true });
        defer source_db.close(io);
        try expectReads(source_db, &expected);
    }

    const imported = try db.bedrock.import(testing.allocator, io, tmp.dir, "bedrock", "zigrite");
    try testing.expectEqual(@as(u64, expected.count()), imported.chunk_records + imported.aux_records);
    try testing.expectEqual(@as(u64, 11), imported.aux_records);
    try testing.expectError(error.PathAlreadyExists, db.bedrock.import(testing.allocator, io, tmp.dir, "bedrock", "zigrite"));
    {
        const dir = try tmp.dir.openDir(io, "zigrite", .{});
        defer dir.close(io);
        var world = try db.World.open(testing.allocator, io, dir, .{});
        defer world.deinit();
        const output = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(output);
        var buffer: [16]u8 = undefined;
        const sub = chunkKey(-40, -33, 2, 0x2f, -4, &buffer);
        try testing.expectEqualSlices(u8, expected.get(sub).?, (try world.get(.{ .dimension = 2, .chunk_x = -40, .chunk_z = -33, .component = .subchunk, .subchunk_y = -4 }, output)).?);
        const player = (try db.aux.get(&world, testing.allocator, "~local_player")).?;
        defer testing.allocator.free(player);
        try testing.expectEqualSlices(u8, expected.get("~local_player").?, player);
        try testing.expectEqual(null, try db.aux.get(&world, testing.allocator, "deleted_or_never_there"));
        var records: [16]db.ChunkRecord = undefined;
        var result: db.ChunkResult = undefined;
        try world.getChunk(1, 31, 5, output, &records, &result);
        try testing.expectEqual(@as(usize, 8), result.count);
        try world.close();
    }

    _ = try db.bedrock.exportWorld(testing.allocator, io, tmp.dir, "zigrite", "back", .zlib_raw);
    const back_db = try tmp.dir.openDir(io, "back/db", .{ .iterate = true });
    defer back_db.close(io);
    try expectReads(back_db, &expected);
    var level: [32]u8 = undefined;
    try testing.expectEqualStrings("level data", try tmp.dir.readFile(io, "back/level.dat", &level));
    try testing.expectEqualStrings("{}", try tmp.dir.readFile(io, "back/behavior_packs/pack.json", &level));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "back/bedrock", .{}));
}

test "uncompressed and zlib exports read back the same" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var expected: Expected = .empty;
    try buildWorld(arena_state.allocator(), tmp.dir, &expected);
    _ = try db.bedrock.import(testing.allocator, io, tmp.dir, "bedrock", "zigrite");
    inline for (.{ .none, .zlib }, .{ "plain", "zlib" }) |compression, name| {
        _ = try db.bedrock.exportWorld(testing.allocator, io, tmp.dir, "zigrite", name, compression);
        const dir = try tmp.dir.openDir(io, name ++ "/db", .{ .iterate = true });
        defer dir.close(io);
        try expectReads(dir, &expected);
    }
}

test "damaged tables fail the import and leave nothing behind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var expected: Expected = .empty;
    try buildWorld(arena_state.allocator(), tmp.dir, &expected);
    const table = try tmp.dir.openFile(io, "bedrock/db/000003.ldb", .{ .mode = .read_write });
    defer table.close(io);
    try table.writePositionalAll(io, "XXXX", 100);
    try testing.expectError(error.ChecksumMismatch, db.bedrock.import(testing.allocator, io, tmp.dir, "bedrock", "zigrite"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "zigrite", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "zigrite" ++ db.stage.suffix, .{}));
}

test "a torn log tail keeps the records before it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const handle = try tmp.dir.createFile(io, "log", .{ .read = true });
    defer handle.close(io);
    var log: leveldb.LogWriter = .{ .file = .{ .handle = handle, .io = io } };
    try log.add("first");
    try log.add("second record");
    const bytes = try tmp.dir.readFileAlloc(io, "log", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    for (12..bytes.len) |cut| {
        var reader: leveldb.LogReader = .{ .bytes = bytes[0..cut] };
        defer reader.deinit(testing.allocator);
        try testing.expectEqualStrings("first", (try reader.next(testing.allocator)).?);
        try testing.expectEqual(null, try reader.next(testing.allocator));
    }
}
