const std = @import("std");

const Key = @import("../format/key.zig").Key;
const Region = @import("../format/key.zig").Region;
const WriteBatch = @import("../batch/write.zig").WriteBatch;
const store_module = @import("../shard/store.zig");
const Store = store_module.Store;
const Directory = @import("../storage/directory.zig").Directory;
const AppendResult = @import("../storage/writer.zig").AppendResult;
const segment = @import("../format/segment.zig");

pub const Options = struct {
    max_open_shards: usize = 16,
    shard: store_module.Options = .{},
};

pub const World = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: Directory,
    options: Options,
    slots: []Slot,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    const Slot = struct {
        region: Region,
        store: *Store,
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !World {
        if (options.max_open_shards == 0 or options.max_open_shards > 1024) return error.InvalidShardLimit;
        try options.shard.validate();
        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();
        const slots = try allocator.alloc(Slot, options.max_open_shards);
        return .{ .allocator = allocator, .io = io, .directory = directory, .options = options, .slots = slots };
    }

    /// Batch IDs are ordered per region.
    pub fn write(self: *World, batch: WriteBatch) !AppendResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        const size = try batch.size();
        if (size > self.options.shard.batch_buffer_size) return error.BufferTooSmall;
        if (size > self.options.shard.max_segment_size - segment.encoded_len) return error.BatchTooLarge;
        const store = (try self.load(batch.entries[0].key.region(), true)).?;
        return store.write(batch);
    }

    pub fn get(self: *World, key: Key, output: []u8) !?[]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        _ = try key.encode();
        const store = (try self.load(key.region(), false)) orelse return null;
        return store.get(key, output);
    }

    pub fn valueSize(self: *World, key: Key) !?u32 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        _ = try key.encode();
        const store = (try self.load(key.region(), false)) orelse return null;
        const location = (try store.shard.index.get(key)) orelse return null;
        return location.raw_len;
    }
    pub fn compact(self: *World, region: Region) !?store_module.CompactionResult {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        const store = (try self.load(region, false)) orelse return null;
        return try store.compact();
    }

    pub fn flush(self: *World) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        var failure: ?anyerror = null;
        for (self.slots[0..self.count]) |slot| {
            slot.store.flush() catch |err| {
                if (failure == null) failure = err;
            };
        }
        if (failure) |err| return err;
    }

    pub fn close(self: *World) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        var failure: ?anyerror = null;
        while (self.count != 0) {
            self.evict() catch |err| {
                if (failure == null) failure = err;
            };
        }
        self.release();
        if (failure) |err| return err;
    }

    pub fn deinit(self: *World) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        for (self.slots[0..self.count]) |slot| {
            slot.store.deinit();
            self.allocator.destroy(slot.store);
        }
        self.release();
    }

    fn load(self: *World, region: Region, create: bool) !?*Store {
        for (self.slots[0..self.count], 0..) |slot, i| {
            if (std.meta.eql(slot.region, region)) {
                std.mem.copyBackwards(Slot, self.slots[1 .. i + 1], self.slots[0..i]);
                self.slots[0] = slot;
                return slot.store;
            }
        }
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{x:0>8}-{x:0>8}-{x:0>8}.region", .{
            @as(u32, @bitCast(region.dimension)),
            @as(u32, @bitCast(region.x)),
            @as(u32, @bitCast(region.z)),
        });
        var created = false;
        const dir = self.directory.dir.openDir(self.io, name, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            if (!create) return null;
            try self.directory.dir.createDir(self.io, name, .default_dir);
            created = true;
            break :blk try self.directory.dir.openDir(self.io, name, .{ .follow_symlinks = false });
        };
        defer dir.close(self.io);
        const store = try self.allocator.create(Store);
        errdefer self.allocator.destroy(store);
        if (self.count == self.slots.len) try self.evict();
        store.* = if (created)
            try Store.create(self.allocator, self.io, dir, region, self.options.shard)
        else
            try Store.open(self.allocator, self.io, dir, self.options.shard);
        errdefer store.deinit();
        if (!std.meta.eql(store.shard.index.region, region)) return error.RegionMismatch;
        try self.directory.syncEntries();
        std.mem.copyBackwards(Slot, self.slots[1 .. self.count + 1], self.slots[0..self.count]);
        self.slots[0] = .{ .region = region, .store = store };
        self.count += 1;
        return store;
    }

    fn evict(self: *World) !void {
        const store = self.slots[self.count - 1].store;
        self.count -= 1;
        defer self.allocator.destroy(store);
        try store.close();
    }

    fn release(self: *World) void {
        self.allocator.free(self.slots);
        self.directory.deinit();
        self.count = 0;
        self.closed = true;
    }
};
