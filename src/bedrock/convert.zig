const std = @import("std");
const builtin = @import("builtin");

const key_format = @import("../format/key.zig");
const Component = key_format.Component;
const Key = key_format.Key;
const Entry = @import("../batch/write.zig").Entry;
const frame = @import("../format/frame.zig");
const World = @import("../world/world.zig").World;
const aux = @import("../world/auxiliary.zig");
const stage = @import("../tool/stage.zig");
const supported = @import("../storage/directory.zig").supported;
const leveldb = @import("leveldb.zig");

pub const files_dir = "bedrock";

pub const Result = struct {
    chunk_records: u64 = 0,
    aux_records: u64 = 0,
    bytes: u64 = 0,
    files: u64 = 0,
};

pub const Problem = stage.Problem;

fn chunkTag(tag: u8) bool {
    return (tag >= 0x2b and tag <= 0x41) or tag == 0x76;
}

pub fn parseKey(bytes: []const u8) ?Key {
    if ((bytes.len == 12 or bytes.len == 16) and std.mem.eql(u8, bytes[0..4], "digp")) {
        const dim: i32 = if (bytes.len == 16) std.mem.readInt(i32, bytes[12..16], .little) else 0;
        if ((bytes.len == 16 and dim == 0) or dim == aux.dimension) return null;
        return .{ .dimension = dim, .chunk_x = std.mem.readInt(i32, bytes[4..8], .little), .chunk_z = std.mem.readInt(i32, bytes[8..12], .little), .component = .actor_digest };
    }
    const with_dim = bytes.len == 13 or bytes.len == 14;
    if (!with_dim and bytes.len != 9 and bytes.len != 10) return null;
    const tag_at: usize = if (with_dim) 12 else 8;
    const tag = bytes[tag_at];
    const has_y = bytes.len == tag_at + 2;
    if (!chunkTag(tag) or has_y != (tag == @backingInt(Component.subchunk))) return null;
    const dim: i32 = if (with_dim) std.mem.readInt(i32, bytes[8..12], .little) else 0;
    if ((with_dim and dim == 0) or dim == aux.dimension) return null;
    return .{
        .dimension = dim,
        .chunk_x = std.mem.readInt(i32, bytes[0..4], .little),
        .chunk_z = std.mem.readInt(i32, bytes[4..8], .little),
        .component = @fromBackingInt(@intCast(tag)),
        .subchunk_y = if (has_y) @as(i8, @bitCast(bytes[tag_at + 1])) else 0,
    };
}

pub fn levelKey(key: Key, out: *[16]u8) []const u8 {
    var len: usize = 0;
    if (key.component == .actor_digest) {
        @memcpy(out[0..4], "digp");
        len = 4;
    }
    std.mem.writeInt(i32, out[len..][0..4], key.chunk_x, .little);
    std.mem.writeInt(i32, out[len + 4 ..][0..4], key.chunk_z, .little);
    len += 8;
    if (key.dimension != 0) {
        std.mem.writeInt(i32, out[len..][0..4], key.dimension, .little);
        len += 4;
    }
    if (key.component == .actor_digest) return out[0..len];
    out[len] = @backingInt(key.component);
    len += 1;
    if (key.component == .subchunk) {
        out[len] = @bitCast(@as(i8, @intCast(key.subchunk_y)));
        len += 1;
    }
    return out[0..len];
}

/// LevelDB's own lock on `db/LOCK`, so a game or server that has the database open can't change it under us.
/// It's an open file description lock, which also conflicts with a LevelDB opened by this same process.
const DatabaseLock = struct {
    file: std.Io.File,

    fn acquire(io: std.Io, db_dir: std.Io.Dir) !DatabaseLock {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
        const linux = std.os.linux;
        const file = try db_dir.createFile(io, "LOCK", .{ .truncate = false, .read = true });
        errdefer file.close(io);
        var lock = std.mem.zeroes(linux.Flock);
        lock.type = linux.F.WRLCK;
        lock.whence = linux.SEEK.SET;
        while (true) switch (linux.errno(linux.fcntl(file.handle, linux.F.OFD_SETLK, @intFromPtr(&lock)))) {
            .SUCCESS => return .{ .file = file },
            .INTR => continue,
            .AGAIN, .ACCES => return error.DirectoryBusy,
            .NOLCK => return error.SystemResources,
            else => return error.LockFailed,
        };
    }

    fn release(self: DatabaseLock, io: std.Io) void {
        self.file.close(io);
    }
};

const LevelDatabase = struct {
    dir: std.Io.Dir,
    lock: DatabaseLock,

    fn open(io: std.Io, world_dir: std.Io.Dir, problem: ?*Problem) !LevelDatabase {
        const dir = world_dir.openDir(io, "db", .{ .iterate = true, .follow_symlinks = false }) catch |err| {
            Problem.set(problem, "can't open the LevelDB database in db: {t}", .{err});
            return err;
        };
        errdefer dir.close(io);
        const lock = DatabaseLock.acquire(io, dir) catch |err| {
            if (err == error.DirectoryBusy) Problem.set(problem, "the LevelDB database is open in another program", .{});
            return err;
        };
        return .{ .dir = dir, .lock = lock };
    }

    fn close(self: LevelDatabase, io: std.Io) void {
        self.lock.release(io);
        self.dir.close(io);
    }
};

fn readNext(reader: *leveldb.Reader, problem: ?*Problem) !?struct { []const u8, []const u8 } {
    return reader.next() catch |err| {
        Problem.set(problem, "the LevelDB database is damaged or unreadable: {t}", .{err});
        return err;
    };
}

/// Copies a Bedrock LevelDB world into a new ZigriteDB world, keeping every record as is, and checks the copy
/// against the source before publishing it.
pub fn import(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, source: []const u8, destination: []const u8, problem: ?*Problem) !Result {
    if (!supported) return error.UnsupportedPlatform;
    const world_dir = try parent.openDir(io, source, .{ .iterate = true });
    defer world_dir.close(io);
    const database = try LevelDatabase.open(io, world_dir, problem);
    defer database.close(io);
    var staged = try stage.Staged.begin(io, parent, destination);
    defer staged.deinit();

    var result: Result = .{};
    try staged.dir.createDir(io, files_dir, .default_dir);
    {
        const files = try staged.dir.openDir(io, files_dir, .{});
        defer files.close(io);
        result.files = stage.copyTree(io, world_dir, files, &.{"db"}) catch |err| {
            Problem.set(problem, "can't copy the world files: {t}", .{err});
            return err;
        };
    }

    {
        // LevelDB order hops between regions, so keep them all open.
        var world = try World.open(allocator, io, staged.dir, .{ .max_open_regions = 1024, .region = .{ .batch_buffer_size = frame.max_bytes + frame.header_len, .compact_live_percent = 0 } });
        defer world.deinit();
        var reader = try leveldb.Reader.open(allocator, io, database.dir);
        defer reader.deinit();
        var batch: Pending = .{ .allocator = allocator };
        defer batch.deinit();
        while (try readNext(&reader, problem)) |item| {
            const key, const value = item;
            result.bytes += value.len;
            if (parseKey(key)) |chunk_key| {
                try batch.add(&world, chunk_key, value);
                result.chunk_records += 1;
            } else {
                aux.put(&world, allocator, key, value) catch |err| {
                    if (err == error.BatchTooLarge) Problem.set(problem, "record {x} is too large for ZigriteDB, or shares a full bucket", .{key});
                    return err;
                };
                result.aux_records += 1;
            }
        }
        try batch.flush(&world);
        try world.close();
    }
    try compactAll(allocator, io, staged.dir);
    _ = try verifyOpen(allocator, io, world_dir, database.dir, staged.dir, problem);
    try staged.publish();
    return result;
}

fn compactAll(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var world = try World.open(allocator, io, dir, .{});
    defer world.deinit();
    const regions = try world.regions(allocator);
    defer allocator.free(regions);
    for (regions) |region| _ = try world.compact(region);
    try world.close();
}

const Pending = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator = undefined,
    started: bool = false,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    bytes: usize = 0,

    const target = 512 * 1024;

    fn deinit(self: *Pending) void {
        if (self.started) self.arena.deinit();
        self.entries.deinit(self.allocator);
    }

    fn add(self: *Pending, world: *World, key: Key, value: []const u8) !void {
        if (self.entries.items.len != 0) {
            const first = self.entries.items[0].key;
            const same = first.dimension == key.dimension and first.chunk_x == key.chunk_x and first.chunk_z == key.chunk_z;
            if (!same or self.bytes + value.len > target or self.entries.items.len == frame.max_records) try self.flush(world);
        }
        if (!self.started) {
            self.arena = .init(self.allocator);
            self.started = true;
        }
        try self.entries.append(self.allocator, .{ .key = key, .value = try self.arena.allocator().dupe(u8, value) });
        self.bytes += value.len;
    }

    fn flush(self: *Pending, world: *World) !void {
        if (self.entries.items.len == 0) return;
        _ = try world.write(.{ .entries = self.entries.items });
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.bytes = 0;
    }
};

const Exported = struct {
    key: []const u8,
    source: union(enum) { chunk: Key, aux: Key },

    fn lessThan(_: void, a: Exported, b: Exported) bool {
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

/// Writes a ZigriteDB world out as a standalone Bedrock LevelDB world and checks it against the source before
/// publishing it.
pub fn exportWorld(allocator: std.mem.Allocator, io: std.Io, parent: std.Io.Dir, source: []const u8, destination: []const u8, compression: leveldb.Compression, problem: ?*Problem) !Result {
    if (!supported) return error.UnsupportedPlatform;
    const source_dir = try parent.openDir(io, source, .{ .iterate = true });
    defer source_dir.close(io);
    var staged = try stage.Staged.begin(io, parent, destination);
    defer staged.deinit();

    var result: Result = .{};
    if (source_dir.openDir(io, files_dir, .{ .iterate = true, .follow_symlinks = false })) |files| {
        defer files.close(io);
        result.files = stage.copyTree(io, files, staged.dir, &.{}) catch |err| {
            Problem.set(problem, "can't copy the world files: {t}", .{err});
            return err;
        };
    } else |err| if (err != error.FileNotFound) return err;

    {
        var world = World.open(allocator, io, source_dir, .{ .max_open_regions = 1024 }) catch |err| {
            if (err == error.DirectoryBusy) Problem.set(problem, "the ZigriteDB world is open in another program", .{});
            return err;
        };
        defer world.deinit();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const keys = arena.allocator();

        // ponytail: every key is held in memory to sort it into LevelDB order, about 60 bytes per record
        var list: std.ArrayListUnmanaged(Exported) = .empty;
        const regions = try world.regions(allocator);
        defer allocator.free(regions);
        for (regions) |region| {
            const found = try world.keys(region, allocator, .{});
            defer allocator.free(found);
            if (aux.isAux(region)) {
                for (found) |bucket| {
                    const bytes = (try world.get(bucket, try buffer(&world, keys, bucket))) orelse continue;
                    var entries: aux.Entries = .{ .bytes = bytes };
                    while (try entries.next()) |entry| try list.append(keys, .{ .key = entry[0], .source = .{ .aux = bucket } });
                }
                continue;
            }
            for (found) |key| {
                var bytes: [16]u8 = undefined;
                try list.append(keys, .{ .key = try keys.dupe(u8, levelKey(key, &bytes)), .source = .{ .chunk = key } });
            }
        }
        std.mem.sort(Exported, list.items, {}, Exported.lessThan);

        try staged.dir.createDir(io, "db", .default_dir);
        const db_dir = try staged.dir.openDir(io, "db", .{});
        defer db_dir.close(io);
        var writer = try leveldb.Writer.init(allocator, io, db_dir, compression);
        defer writer.deinit();
        var value: std.ArrayListUnmanaged(u8) = .empty;
        defer value.deinit(allocator);
        for (list.items) |item| {
            const bytes = switch (item.source) {
                .chunk => |key| blk: {
                    const size = (try world.valueSize(key)) orelse return error.FileChanged;
                    try value.resize(allocator, size);
                    result.chunk_records += 1;
                    break :blk (try world.get(key, value.items)).?;
                },
                .aux => blk: {
                    result.aux_records += 1;
                    break :blk auxValue(item.key);
                },
            };
            result.bytes += bytes.len;
            writer.add(item.key, bytes) catch |err| {
                if (err == error.KeyOrder) Problem.set(problem, "the ZigriteDB world holds record {x} twice", .{item.key});
                return err;
            };
        }
        try writer.finish();
        try world.close();
    }
    _ = try verify(allocator, io, staged.dir, source_dir, problem);
    try staged.publish();
    return result;
}

fn buffer(world: *World, allocator: std.mem.Allocator, key: Key) ![]u8 {
    return allocator.alloc(u8, (try world.valueSize(key)) orelse 0);
}

fn auxValue(key: []const u8) []const u8 {
    const after = key.ptr + key.len;
    const len = std.mem.readInt(u32, after[0..4], .little);
    return (after + 4)[0..len];
}

/// Checks that a ZigriteDB world holds exactly the records of a Bedrock LevelDB world, byte for byte, and the same
/// world files. Fails with error.VerificationFailed and a Problem naming the first difference.
pub fn verify(allocator: std.mem.Allocator, io: std.Io, level_world: std.Io.Dir, zigrite_world: std.Io.Dir, problem: ?*Problem) !Result {
    if (!supported) return error.UnsupportedPlatform;
    const database = try LevelDatabase.open(io, level_world, problem);
    defer database.close(io);
    return verifyOpen(allocator, io, level_world, database.dir, zigrite_world, problem);
}

fn verifyOpen(allocator: std.mem.Allocator, io: std.Io, level_world: std.Io.Dir, db_dir: std.Io.Dir, zigrite_world: std.Io.Dir, problem: ?*Problem) !Result {
    var result: Result = .{};
    {
        var world = World.open(allocator, io, zigrite_world, .{ .max_open_regions = 1024 }) catch |err| {
            if (err == error.DirectoryBusy) Problem.set(problem, "the ZigriteDB world is open in another program", .{});
            return err;
        };
        defer world.deinit();
        var reader = try leveldb.Reader.open(allocator, io, db_dir);
        defer reader.deinit();
        var value: []u8 = &.{};
        defer allocator.free(value);
        while (try readNext(&reader, problem)) |item| {
            const key, const expected = item;
            result.bytes += expected.len;
            if (parseKey(key)) |chunk| {
                result.chunk_records += 1;
                const stored = try readSized(&world, allocator, chunk, &value);
                if (stored == null or !std.mem.eql(u8, stored.?, expected)) return mismatch(problem, key, stored == null);
            } else {
                result.aux_records += 1;
                const stored = try aux.get(&world, allocator, key);
                defer if (stored) |bytes| allocator.free(bytes);
                if (stored == null or !std.mem.eql(u8, stored.?, expected)) return mismatch(problem, key, stored == null);
            }
        }

        var chunk_records: u64 = 0;
        var aux_records: u64 = 0;
        const regions = try world.regions(allocator);
        defer allocator.free(regions);
        for (regions) |region| {
            const found = try world.keys(region, allocator, .{});
            defer allocator.free(found);
            if (!aux.isAux(region)) {
                chunk_records += found.len;
                continue;
            }
            for (found) |bucket| {
                const bytes = (try readSized(&world, allocator, bucket, &value)) orelse continue;
                var entries: aux.Entries = .{ .bytes = bytes };
                while (try entries.next()) |_| aux_records += 1;
            }
        }
        if (chunk_records != result.chunk_records or aux_records != result.aux_records) {
            Problem.set(problem, "ZigriteDB holds {} chunk and {} other records but LevelDB holds {} and {}", .{ chunk_records, aux_records, result.chunk_records, result.aux_records });
            return error.VerificationFailed;
        }
        try world.close();
    }

    if (zigrite_world.openDir(io, files_dir, .{ .iterate = true, .follow_symlinks = false })) |files| {
        defer files.close(io);
        result.files = try sameTree(io, level_world, files, "db", problem);
    } else |err| {
        if (err != error.FileNotFound) return err;
        // Nothing but db may sit next to the database when the world has no file directory.
        var iterator = level_world.iterate();
        while (try iterator.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, "db")) continue;
            Problem.set(problem, "world file {s} is missing from the ZigriteDB world", .{entry.name});
            return error.VerificationFailed;
        }
    }
    return result;
}

/// Reads into a reused buffer, growing it to fit.
fn readSized(world: *World, allocator: std.mem.Allocator, key: Key, value: *[]u8) !?[]const u8 {
    while (true) {
        var required: usize = 0;
        return world.getSized(key, value.*, &required) catch |err| {
            if (err != error.BufferTooSmall) return err;
            allocator.free(value.*);
            value.* = &.{};
            value.* = try allocator.alloc(u8, required);
            continue;
        };
    }
}

fn mismatch(problem: ?*Problem, key: []const u8, missing: bool) error{VerificationFailed} {
    if (missing) Problem.set(problem, "record {x} is missing from the ZigriteDB world", .{key}) else Problem.set(problem, "record {x} differs between the worlds", .{key});
    return error.VerificationFailed;
}

/// Compares two directory trees by name, kind and content. Returns how many files matched.
fn sameTree(io: std.Io, a: std.Io.Dir, b: std.Io.Dir, skip: ?[]const u8, problem: ?*Problem) !u64 {
    var files: u64 = 0;
    var entries_a: u64 = 0;
    var iterator = a.iterate();
    while (try iterator.next(io)) |entry| {
        if (skip) |name| if (std.mem.eql(u8, entry.name, name)) continue;
        entries_a += 1;
        const other = b.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            if (err != error.FileNotFound) return err;
            Problem.set(problem, "world file {s} is missing from one of the worlds", .{entry.name});
            return error.VerificationFailed;
        };
        switch (entry.kind) {
            .file => {
                if (other.kind != .file or !try sameFile(io, a, b, entry.name)) {
                    Problem.set(problem, "world file {s} differs between the worlds", .{entry.name});
                    return error.VerificationFailed;
                }
                files += 1;
            },
            .directory => {
                if (other.kind != .directory) {
                    Problem.set(problem, "world file {s} differs between the worlds", .{entry.name});
                    return error.VerificationFailed;
                }
                const child_a = try a.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child_a.close(io);
                const child_b = try b.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                defer child_b.close(io);
                files += try sameTree(io, child_a, child_b, null, problem);
            },
            else => {
                Problem.set(problem, "world file {s} is not a regular file or directory", .{entry.name});
                return error.UnsupportedFileType;
            },
        }
    }
    var entries_b: u64 = 0;
    var other_iterator = b.iterate();
    while (try other_iterator.next(io)) |_| entries_b += 1;
    if (entries_a != entries_b) {
        Problem.set(problem, "one world has world files the other lacks", .{});
        return error.VerificationFailed;
    }
    return files;
}

fn sameFile(io: std.Io, a: std.Io.Dir, b: std.Io.Dir, name: []const u8) !bool {
    const file_a = try a.openFile(io, name, .{});
    defer file_a.close(io);
    const file_b = try b.openFile(io, name, .{});
    defer file_b.close(io);
    const len = try file_a.length(io);
    if (len != try file_b.length(io)) return false;
    var buffer_a: [64 * 1024]u8 = undefined;
    var buffer_b: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < len) {
        const want: usize = @intCast(@min(buffer_a.len, len - offset));
        if (try file_a.readPositionalAll(io, buffer_a[0..want], offset) != want) return false;
        if (try file_b.readPositionalAll(io, buffer_b[0..want], offset) != want) return false;
        if (!std.mem.eql(u8, buffer_a[0..want], buffer_b[0..want])) return false;
        offset += want;
    }
    return true;
}

test "chunk keys map both ways and everything else is left alone" {
    var out: [16]u8 = undefined;
    const cases = [_][]const u8{
        &.{ 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 0x2c },
        &.{ 1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 0x2f, 0xfc },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0x2b },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0x2f, 7 },
        "digp" ++ &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0 },
        "digp" ++ &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0 },
    };
    for (cases) |bytes| try std.testing.expectEqualSlices(u8, bytes, levelKey(parseKey(bytes).?, &out));
    const others = [_][]const u8{
        "~local_player",
        "BiomeData",
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0x2c, 9 },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0x2f },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x2c },
        &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0x99 },
        "digp" ++ &[_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 },
        "actorprefix" ++ &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 },
    };
    for (others) |bytes| try std.testing.expectEqual(null, parseKey(bytes));
}
