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
    closing: bool = false,
    changed: std.Io.Condition = .init,

    const Slot = struct {
        region: Region,
        store: *Store,
        users: usize = 0,
    };

    /// Concurrent calls need a thread-safe allocator.
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
        const size = try batch.size();
        if (size > self.options.shard.batch_buffer_size) return error.BufferTooSmall;
        if (size > self.options.shard.max_segment_size - segment.encoded_len) return error.BatchTooLarge;
        const store = (try self.acquire(batch.entries[0].key.region(), true)).?;
        defer self.unpin(store);
        return store.write(batch);
    }

    pub fn writeGroup(self: *World, batches: []const WriteBatch) !void {
        try @import("../batch/group.zig").validate(batches);
        for (batches) |batch| {
            const size = try batch.size();
            if (size > self.options.shard.batch_buffer_size) return error.BufferTooSmall;
            if (size > self.options.shard.max_segment_size - segment.encoded_len) return error.BatchTooLarge;
        }
        const store = (try self.acquire(batches[0].entries[0].key.region(), true)).?;
        defer self.unpin(store);
        try store.writeGroup(batches);
    }

    pub fn get(self: *World, key: Key, output: []u8) !?[]const u8 {
        _ = try key.encode();
        const store = (try self.acquire(key.region(), false)) orelse return null;
        defer self.unpin(store);
        return store.get(key, output);
    }

    pub fn getSized(self: *World, key: Key, output: []u8, required: *usize) !?[]const u8 {
        required.* = 0;
        _ = try key.encode();
        const store = (try self.acquire(key.region(), false)) orelse return null;
        defer self.unpin(store);
        return store.getSized(key, output, required);
    }

    pub fn lastBatchId(self: *World, region: Region) !?u64 {
        const store = (try self.acquire(region, false)) orelse return null;
        defer self.unpin(store);
        return try store.lastBatchId();
    }

    pub fn valueSize(self: *World, key: Key) !?u32 {
        _ = try key.encode();
        const store = (try self.acquire(key.region(), false)) orelse return null;
        defer self.unpin(store);
        return store.valueSize(key);
    }
    pub fn compact(self: *World, region: Region) !?store_module.CompactionResult {
        const store = (try self.acquire(region, false)) orelse return null;
        defer self.unpin(store);
        return try store.compact();
    }

    /// Flushes the shards cached when this call starts.
    pub fn flush(self: *World) !void {
        var stores: [1024]*Store = undefined;
        try self.mutex.lock(self.io);
        if (self.closed or self.closing) {
            self.mutex.unlock(self.io);
            return error.Closed;
        }
        const count = self.count;
        for (self.slots[0..count], 0..) |*slot, i| {
            slot.users += 1;
            stores[i] = slot.store;
        }
        self.mutex.unlock(self.io);
        defer for (stores[0..count]) |store| self.unpin(store);
        var failure: ?anyerror = null;
        for (stores[0..count]) |store| {
            store.flush() catch |err| {
                if (failure == null) failure = err;
            };
        }
        if (failure) |err| return err;
    }

    pub fn close(self: *World) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.closing and !self.closed) self.changed.waitUncancelable(self.io, &self.mutex);
        if (self.closed) return;
        self.closing = true;
        while (self.inUse()) self.changed.waitUncancelable(self.io, &self.mutex);
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
        while (self.closing and !self.closed) self.changed.waitUncancelable(self.io, &self.mutex);
        if (self.closed) return;
        self.closing = true;
        while (self.inUse()) self.changed.waitUncancelable(self.io, &self.mutex);
        for (self.slots[0..self.count]) |slot| {
            slot.store.deinit();
            self.allocator.destroy(slot.store);
        }
        self.release();
    }

    fn acquire(self: *World, region: Region, create: bool) !?*Store {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.closed or self.closing) return error.Closed;
            for (self.slots[0..self.count], 0..) |slot, i| {
                if (!std.meta.eql(slot.region, region)) continue;
                std.mem.copyBackwards(Slot, self.slots[1 .. i + 1], self.slots[0..i]);
                self.slots[0] = slot;
                self.slots[0].users += 1;
                return slot.store;
            }
            if (self.count < self.slots.len or self.hasIdle()) {
                const store = (try self.load(region, create)) orelse return null;
                self.slots[0].users = 1;
                return store;
            }
            try self.changed.wait(self.io, &self.mutex);
        }
    }

    fn unpin(self: *World, store: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.slots[0..self.count]) |*slot| {
            if (slot.store != store) continue;
            std.debug.assert(slot.users != 0);
            slot.users -= 1;
            self.changed.broadcast(self.io);
            return;
        }
        unreachable;
    }

    fn hasIdle(self: *World) bool {
        for (self.slots[0..self.count]) |slot| {
            if (slot.users == 0) return true;
        }
        return false;
    }

    fn inUse(self: *World) bool {
        for (self.slots[0..self.count]) |slot| {
            if (slot.users != 0) return true;
        }
        return false;
    }

    fn load(self: *World, region: Region, create: bool) !?*Store {
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
        var i = self.count;
        while (i != 0) {
            i -= 1;
            if (self.slots[i].users == 0) break;
        }
        std.debug.assert(self.slots[i].users == 0);
        const store = self.slots[i].store;
        std.mem.copyForwards(Slot, self.slots[i .. self.count - 1], self.slots[i + 1 .. self.count]);
        self.count -= 1;
        defer self.allocator.destroy(store);
        try store.close();
    }

    fn release(self: *World) void {
        self.allocator.free(self.slots);
        self.directory.deinit();
        self.count = 0;
        self.closed = true;
        self.changed.broadcast(self.io);
    }
};
