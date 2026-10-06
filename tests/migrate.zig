const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const crc = db.crc;

/// Minimal format 1 writer.
const V1 = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    batch_start: usize = 0,
    count: u32 = 0,

    fn deinit(self: *V1) void {
        self.bytes.deinit(testing.allocator);
    }

    fn segment(self: *V1, id: u64) !void {
        var header = [_]u8{0} ** 48;
        @memcpy(header[0..4], "ZGSG");
        std.mem.writeInt(u16, header[4..6], 1, .little);
        std.mem.writeInt(u64, header[8..16], id, .little);
        std.mem.writeInt(u64, header[16..24], 1, .little);
        std.mem.writeInt(u32, header[44..48], crc.hash(header[0..44]), .little);
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(testing.allocator, &header);
        self.batch_start = self.bytes.items.len;
    }

    fn recordHeader(kind: u8, compression: u8, stored: u32, raw: u32, id: u64) [32]u8 {
        var header = [_]u8{0} ** 32;
        @memcpy(header[0..4], "ZGRC");
        header[4] = 1;
        header[5] = kind;
        header[6] = compression;
        std.mem.writeInt(u32, header[8..12], stored, .little);
        std.mem.writeInt(u32, header[12..16], raw, .little);
        std.mem.writeInt(u64, header[16..24], id, .little);
        std.mem.writeInt(u32, header[28..32], crc.hash(header[0..28]), .little);
        return header;
    }

    fn put(self: *V1, id: u64, x: i32, component: u8, y: i32, value: ?[]const u8, compressed_raw: ?u32) !void {
        const start = self.bytes.items.len;
        const stored: []const u8 = value orelse "";
        const header = recordHeader(if (value == null) 2 else 1, if (compressed_raw != null) 1 else 0, @intCast(stored.len), compressed_raw orelse @intCast(stored.len), id);
        try self.bytes.appendSlice(testing.allocator, &header);
        var key: [17]u8 = undefined;
        std.mem.writeInt(i32, key[0..4], 0, .little);
        std.mem.writeInt(i32, key[4..8], x, .little);
        std.mem.writeInt(i32, key[8..12], 0, .little);
        key[12] = component;
        std.mem.writeInt(i32, key[13..17], y, .little);
        try self.bytes.appendSlice(testing.allocator, &key);
        try self.bytes.appendSlice(testing.allocator, stored);
        var sum: [4]u8 = undefined;
        std.mem.writeInt(u32, &sum, crc.hash(self.bytes.items[start..]), .little);
        try self.bytes.appendSlice(testing.allocator, &sum);
        self.count += 1;
    }

    fn commit(self: *V1, id: u64) !void {
        const records = self.bytes.items[self.batch_start..];
        var marker: [80]u8 = undefined;
        @memcpy(marker[0..32], &recordHeader(3, 0, 0, 0, id));
        std.mem.writeInt(u32, marker[32..36], self.count, .little);
        std.mem.writeInt(u64, marker[36..44], records.len, .little);
        std.crypto.hash.sha2.Sha256.hash(records, marker[44..76], .{});
        std.mem.writeInt(u32, marker[76..80], crc.hash(marker[0..76]), .little);
        try self.bytes.appendSlice(testing.allocator, &marker);
        self.batch_start = self.bytes.items.len;
        self.count = 0;
    }

    fn save(self: *V1, dir: std.Io.Dir, id: u64) !void {
        var name: [48]u8 = undefined;
        try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "{x:0>16}-{x:0>16}.segment", .{ @as(u64, 1), id }), .data = self.bytes.items });
    }
};

fn writeManifest(dir: std.Io.Dir, ids: []const u64) !void {
    var bytes: [48 + 16 + 4]u8 = [_]u8{0} ** (48 + 16 + 4);
    const len = 48 + ids.len * 8 + 4;
    @memcpy(bytes[0..4], "ZGMF");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u64, bytes[8..16], 1, .little);
    std.mem.writeInt(u32, bytes[28..32], @intCast(ids.len), .little);
    std.mem.writeInt(u64, bytes[32..40], ids[ids.len - 1], .little);
    std.mem.writeInt(u32, bytes[44..48], crc.hash(bytes[0..44]), .little);
    for (ids, 0..) |id, i| std.mem.writeInt(u64, bytes[48 + i * 8 ..][0..8], id, .little);
    std.mem.writeInt(u32, bytes[len - 4 ..][0..4], crc.hash(bytes[0 .. len - 4]), .little);
    try dir.writeFile(io, .{ .sub_path = "MANIFEST", .data = bytes[0..len] });
}

fn buildV1(parent: std.Io.Dir) ![1024]u8 {
    try parent.createDir(io, "old", .default_dir);
    const world = try parent.openDir(io, "old", .{});
    defer world.close(io);
    try world.writeFile(io, .{ .sub_path = "level.dat", .data = "level" });
    try world.createDir(io, "00000000-00000000-00000000.region", .default_dir);
    const region = try world.openDir(io, "00000000-00000000-00000000.region", .{});
    defer region.close(io);

    var raw: [1024]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @truncate(i / 64);
    var compressed: [1200]u8 = undefined;
    var encoder: db.lz4.Encoder = .{};
    const packed_bytes = try encoder.compress(&raw, &compressed);

    var v1: V1 = .{};
    defer v1.deinit();
    try v1.segment(1);
    try v1.put(1, 0, 5, 0, "old", null);
    try v1.put(1, 1, 0, -2, "sub", null);
    try v1.commit(1);
    try v1.put(2, 0, 5, 0, packed_bytes, raw.len);
    try v1.put(2, 1, 0, -2, null, null);
    try v1.commit(2);
    try v1.save(region, 1);
    try v1.segment(2);
    try v1.put(3, 2, 3, 0, "ent", null);
    try v1.commit(3);
    try v1.put(4, 3, 5, 0, "torn", null);
    try v1.save(region, 2);
    try writeManifest(region, &.{ 1, 2 });
    return raw;
}

test "a format 1 world migrates committed batches, maps components, and keeps other files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const raw = try buildV1(tmp.dir);

    try testing.expectError(error.NeedsMigration, blk: {
        const old = try tmp.dir.openDir(io, "old", .{});
        defer old.close(io);
        break :blk db.World.open(testing.allocator, io, old, .{});
    });

    const result = try db.migrate.migrate(testing.allocator, io, tmp.dir, "old", "new");
    try testing.expectEqual(@as(usize, 1), result.regions);
    try testing.expectEqual(@as(u64, 3), result.batches);
    try testing.expect(result.omitted_tail_bytes > 0);
    try testing.expectError(error.PathAlreadyExists, db.migrate.migrate(testing.allocator, io, tmp.dir, "old", "new"));

    const dir = try tmp.dir.openDir(io, "new", .{});
    defer dir.close(io);
    var level: [16]u8 = undefined;
    try testing.expectEqualStrings("level", try dir.readFile(io, "level.dat", &level));
    var world = try db.World.open(testing.allocator, io, dir, .{});
    defer world.deinit();
    var output: [1024]u8 = undefined;
    try testing.expectEqualSlices(u8, &raw, (try world.get(.{ .dimension = 0, .chunk_x = 0, .chunk_z = 0, .component = .version }, &output)).?);
    try testing.expectEqual(null, try world.get(.{ .dimension = 0, .chunk_x = 1, .chunk_z = 0, .component = .subchunk, .subchunk_y = -2 }, &output));
    try testing.expectEqualStrings("ent", (try world.get(.{ .dimension = 0, .chunk_x = 2, .chunk_z = 0, .component = .entities }, &output)).?);
    try testing.expectEqual(null, try world.get(.{ .dimension = 0, .chunk_x = 3, .chunk_z = 0, .component = .version }, &output));
    try testing.expectEqual(@as(?u64, 3), try world.lastBatchId(.{ .dimension = 0, .x = 0, .z = 0 }));
    try world.close();
}

test "a failed migration leaves no destination and the source untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = try buildV1(tmp.dir);
    const old = try tmp.dir.openDir(io, "old", .{});
    defer old.close(io);
    const region = try old.openDir(io, "00000000-00000000-00000000.region", .{});
    defer region.close(io);
    const file = try region.openFile(io, "0000000000000001-0000000000000001.segment", .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, "X", 48 + 32 + 17);
    const before = try region.readFileAlloc(io, "0000000000000001-0000000000000001.segment", testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    try testing.expectError(error.IncompleteBatch, db.migrate.migrate(testing.allocator, io, tmp.dir, "old", "new"));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new" ++ db.stage.suffix, .{}));
    const after = try region.readFileAlloc(io, "0000000000000001-0000000000000001.segment", testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
}
