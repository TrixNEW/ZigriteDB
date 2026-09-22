const std = @import("std");

const WriteBatch = @import("../batch/write.zig").WriteBatch;
const Key = @import("../format/key.zig").Key;
const Region = @import("../format/key.zig").Region;
const segment = @import("../format/segment.zig");
const store_module = @import("../shard/store.zig");
const Store = store_module.Store;
const Directory = @import("../storage/directory.zig").Directory;
const AppendResult = @import("../storage/writer.zig").AppendResult;

const cache_module = @import("../cache/value.zig");

pub const Options = struct {
    max_open_shards: usize = 16,
    shard: store_module.Options = .{},
    cache: cache_module.Options = .{},
};

pub const ReadRequest = store_module.ReadRequest;
pub const ReadStatus = store_module.ReadStatus;
pub const ReadResult = store_module.ReadResult;
pub const max_distinct_regions = 8;

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

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !World {
        if (options.max_open_shards == 0 or options.max_open_shards > 1024) return error.InvalidShardLimit;
        try options.shard.validate();
        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();
        const slots = try allocator.alloc(Slot, options.max_open_shards);
        errdefer allocator.free(slots);

        var result: World = .{ .allocator = allocator, .io = io, .directory = directory, .options = options, .slots = slots };
        if (options.cache.bytes > 0) {
            const cache = try allocator.create(cache_module.Cache);
            errdefer allocator.destroy(cache);
            cache.* = try cache_module.Cache.init(allocator, options.cache);
            cache.stats = options.shard.stats;
            result.options.shard.cache = cache;
        }
        return result;
    }

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

    pub fn getMany(self: *World, requests: []const ReadRequest, results: []ReadResult) !void {
        std.debug.assert(requests.len == results.len);
        for (requests) |request| _ = try request.key.encode();
        @memset(results, .{});
        if (requests.len == 0) return;

        var regions: [max_distinct_regions]Region = undefined;
        var region_count: usize = 0;
        for (requests) |request| {
            const found = request.key.region();
            const seen = for (regions[0..region_count]) |existing| {
                if (std.meta.eql(existing, found)) break true;
            } else false;
            if (seen) continue;
            if (region_count == regions.len) return error.TooManyKeys;
            regions[region_count] = found;
            region_count += 1;
        }

        var sub_requests: [store_module.max_batch_keys]ReadRequest = undefined;
        var sub_indices: [store_module.max_batch_keys]usize = undefined;
        var sub_results: [store_module.max_batch_keys]ReadResult = undefined;

        for (regions[0..region_count]) |region| {
            var sub_count: usize = 0;
            for (requests, 0..) |request, i| {
                if (!std.meta.eql(request.key.region(), region)) continue;
                if (sub_count == sub_requests.len) return error.TooManyKeys;
                sub_requests[sub_count] = request;
                sub_indices[sub_count] = i;
                sub_count += 1;
            }

            const store = (try self.acquire(region, false)) orelse continue;
            defer self.unpin(store);
            try store.getMany(sub_requests[0..sub_count], sub_results[0..sub_count]);
            for (sub_indices[0..sub_count], sub_results[0..sub_count]) |i, result| results[i] = result;
        }
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
            Store.open(self.allocator, self.io, dir, self.options.shard) catch |err| blk: {
                if (err != error.MissingManifest or !create) return err;
                break :blk Store.create(self.allocator, self.io, dir, region, self.options.shard) catch |create_err| {
                    if (create_err == error.DirectoryNotEmpty) return error.MissingManifest;
                    return create_err;
                };
            };
        errdefer store.deinit();
        if (!std.meta.eql(store.shard.generation.index.region, region)) return error.RegionMismatch;
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
        if (self.options.shard.cache) |cache| {
            cache.deinit();
            self.allocator.destroy(cache);
            self.options.shard.cache = null;
        }
        self.allocator.free(self.slots);
        self.directory.deinit();
        self.count = 0;
        self.closed = true;
        self.changed.broadcast(self.io);
    }
};
