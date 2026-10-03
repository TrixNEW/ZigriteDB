//! One-time conversion of format 1 worlds.
const std = @import("std");

const crc = @import("../format/crc.zig");
const lz4 = @import("../compression/lz4.zig");
const key_format = @import("../format/key.zig");
const Component = key_format.Component;
const Key = key_format.Key;
const Region = key_format.Region;
const write_module = @import("../batch/write.zig");
const world_module = @import("../world/world.zig");
const World = world_module.World;
const stage = @import("stage.zig");

pub const Result = struct {
    regions: usize = 0,
    batches: u64 = 0,
    records: u64 = 0,
    omitted_tail_bytes: u64 = 0,
};

pub fn component(old: u8) !Component {
    return switch (old) {
        0 => .subchunk,
        1 => .data3d,
        2 => .block_entities,
        3 => .entities,
        4 => .data2d,
        5 => .version,
        else => error.UnknownComponent,
    };
}

/// The source is only read; the destination appears once complete.
pub fn migrate(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, source: []const u8, destination: []const u8) !Result {
    const input = try parent.openDir(io, source, .{ .iterate = true, .follow_symlinks = false });
    defer input.close(io);
    var staged = try stage.Staged.begin(io, parent, destination);
    defer staged.deinit();

    var result: Result = .{};
    {
        var world = try World.open(allocator, io, staged.dir, .{ .region = .{ .batch_buffer_size = @import("../format/frame.zig").max_bytes + @import("../format/frame.zig").header_len, .compact_live_percent = 0 } });
        defer world.deinit();
        var iterator = input.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (World.parseRegionName(entry.name) == null) continue;
                const dir = try input.openDir(io, entry.name, .{ .follow_symlinks = false });
                defer dir.close(io);
                try migrateRegion(allocator, io, dir, &world, &result);
                result.regions += 1;
            } else if (entry.kind == .file and !std.mem.eql(u8, entry.name, world_module.format_file)) {
                try input.copyFile(entry.name, staged.dir, entry.name, io, .{});
            }
        }
        try world.close();
    }
    try staged.publish();
    return result;
}

const record_len = 32;
const key_len = 17;
const commit_len = 80;
const max_bytes = 64 * 1024 * 1024;

fn migrateRegion(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, world: *World, result: *Result) !void {
    const manifest = try dir.readFileAlloc(io, "MANIFEST", allocator, .limited(48 + 4096 * 8 + 4));
    defer allocator.free(manifest);
    if (manifest.len < 52 or !std.mem.eql(u8, manifest[0..4], "ZGMF")) return error.InvalidMagic;
    if (std.mem.readInt(u16, manifest[4..6], .little) != 1) return error.UnsupportedVersion;
    if (std.mem.readInt(u32, manifest[44..48], .little) != crc.hash(manifest[0..44])) return error.ChecksumMismatch;
    if (std.mem.readInt(u32, manifest[manifest.len - 4 ..][0..4], .little) != crc.hash(manifest[0 .. manifest.len - 4])) return error.ChecksumMismatch;
    const generation = std.mem.readInt(u64, manifest[8..16], .little);
    const region: Region = .{
        .dimension = std.mem.readInt(i32, manifest[16..20], .little),
        .x = std.mem.readInt(i32, manifest[20..24], .little),
        .z = std.mem.readInt(i32, manifest[24..28], .little),
    };
    const count = std.mem.readInt(u32, manifest[28..32], .little);
    if (manifest.len != 48 + count * 8 + 4 or count == 0) return error.InvalidLength;

    var last_id: u64 = 0;
    for (0..count) |i| {
        const id = std.mem.readInt(u64, manifest[48 + i * 8 ..][0..8], .little);
        var name: [48]u8 = undefined;
        const bytes = try dir.readFileAlloc(io, try std.fmt.bufPrint(&name, "{x:0>16}-{x:0>16}.segment", .{ generation, id }), allocator, .unlimited);
        defer allocator.free(bytes);
        try checkSegment(bytes, generation, id, region);
        var reader: Reader = .{ .bytes = bytes, .offset = 48, .region = region };
        defer reader.deinit(allocator);
        while (try reader.next(allocator, &last_id)) |batch| {
            defer reader.release(allocator);
            _ = try world.write(batch);
            result.batches += 1;
            result.records += batch.entries.len;
        }
        if (reader.offset != bytes.len) {
            // Only the active segment may end in a torn batch.
            if (i != count - 1) return error.IncompleteBatch;
            result.omitted_tail_bytes += bytes.len - reader.offset;
        }
    }
}

fn checkSegment(bytes: []const u8, generation: u64, id: u64, region: Region) !void {
    if (bytes.len < 48 or !std.mem.eql(u8, bytes[0..4], "ZGSG")) return error.InvalidMagic;
    if (std.mem.readInt(u16, bytes[4..6], .little) != 1) return error.UnsupportedVersion;
    if (std.mem.readInt(u32, bytes[44..48], .little) != crc.hash(bytes[0..44])) return error.ChecksumMismatch;
    const same = std.mem.readInt(u64, bytes[8..16], .little) == id and std.mem.readInt(u64, bytes[16..24], .little) == generation and
        std.mem.readInt(i32, bytes[24..28], .little) == region.dimension and std.mem.readInt(i32, bytes[28..32], .little) == region.x and
        std.mem.readInt(i32, bytes[32..36], .little) == region.z;
    if (!same) return error.IdentityMismatch;
}

/// Stops at a torn or damaged tail.
const Reader = struct {
    bytes: []const u8,
    offset: usize,
    region: Region,
    entries: std.ArrayListUnmanaged(write_module.Entry) = .empty,
    values: std.ArrayListUnmanaged([]u8) = .empty,

    fn release(self: *Reader, allocator: std.mem.Allocator) void {
        for (self.values.items) |value| allocator.free(value);
        self.values.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
    }

    fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        self.release(allocator);
        self.values.deinit(allocator);
        self.entries.deinit(allocator);
    }

    fn next(self: *Reader, allocator: std.mem.Allocator, last_id: *u64) !?write_module.WriteBatch {
        var at = self.offset;
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        var batch_id: u64 = 0;
        var count: u32 = 0;
        while (true) {
            if (self.bytes.len - at < record_len) return self.tail(allocator);
            const header = self.bytes[at..][0..record_len];
            if (!std.mem.eql(u8, header[0..4], "ZGRC") or header[4] != 1 or
                std.mem.readInt(u32, header[28..32], .little) != crc.hash(header[0..28])) return self.tail(allocator);
            const kind = header[5];
            const id = std.mem.readInt(u64, header[16..24], .little);
            if (kind == 3) {
                if (self.bytes.len - at < commit_len) return self.tail(allocator);
                const commit = self.bytes[at..][0..commit_len];
                var digest: [32]u8 = undefined;
                sha.final(&digest);
                const valid = std.mem.readInt(u32, commit[76..80], .little) == crc.hash(commit[0..76]) and count != 0 and
                    id == batch_id and std.mem.readInt(u32, commit[32..36], .little) == count and
                    std.mem.readInt(u64, commit[36..44], .little) == at - self.offset and std.mem.eql(u8, commit[44..76], &digest);
                if (!valid) return self.tail(allocator);
                if (batch_id <= last_id.*) return error.BatchOrder;
                last_id.* = batch_id;
                self.offset = at + commit_len;
                return .{ .id = batch_id, .entries = self.entries.items };
            }
            if (kind != 1 and kind != 2) return self.tail(allocator);
            const stored = std.mem.readInt(u32, header[8..12], .little);
            const raw = std.mem.readInt(u32, header[12..16], .little);
            const len = record_len + key_len + @as(usize, stored) + 4;
            if (self.bytes.len - at < len) return self.tail(allocator);
            const bytes = self.bytes[at..][0..len];
            if (std.mem.readInt(u32, bytes[len - 4 ..][0..4], .little) != crc.hash(bytes[0 .. len - 4])) return self.tail(allocator);
            if (count != 0 and id != batch_id) return error.BatchMismatch;
            batch_id = id;
            const k = bytes[record_len..][0..key_len];
            const y = std.mem.readInt(i32, k[13..17], .little);
            const key: Key = .{
                .dimension = std.mem.readInt(i32, k[0..4], .little),
                .chunk_x = std.mem.readInt(i32, k[4..8], .little),
                .chunk_z = std.mem.readInt(i32, k[8..12], .little),
                .component = try component(k[12]),
                .subchunk_y = y,
            };
            try key.validate();
            if (!key.region().eql(self.region)) return error.RegionMismatch;
            const stored_value = bytes[record_len + key_len ..][0..stored];
            const value: ?[]const u8 = if (kind == 2) null else switch (header[6]) {
                0 => stored_value,
                1 => blk: {
                    const buffer = try allocator.alloc(u8, raw);
                    try self.values.append(allocator, buffer);
                    break :blk try lz4.decompress(stored_value, buffer, raw);
                },
                else => return error.UnsupportedCompression,
            };
            try self.entries.append(allocator, .{ .key = key, .value = value });
            sha.update(bytes);
            count += 1;
            at += len;
        }
    }

    fn tail(self: *Reader, allocator: std.mem.Allocator) ?write_module.WriteBatch {
        self.release(allocator);
        return null;
    }
};
