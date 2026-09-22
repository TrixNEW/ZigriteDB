const std = @import("std");

const WriteBatch = @import("../batch/write.zig").WriteBatch;
const key_format = @import("../format/key.zig");
const Key = key_format.Key;
const KeyFilter = key_format.KeyFilter;
const Entry = @import("../format/entry.zig").Entry;
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
    missing: [256]?Region = .{null} ** 256,

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

    pub fn writeNext(self: *World, entries: []Entry) !AppendResult {
        for (entries) |*item| item.header.batch_id = 1;
        const batch: WriteBatch = .{ .entries = entries };
        const size = try batch.size();
        if (size > self.options.shard.batch_buffer_size) return error.BufferTooSmall;
        if (size > self.options.shard.max_segment_size - segment.encoded_len) return error.BatchTooLarge;
        const store = (try self.acquire(entries[0].key.region(), true)).?;
        defer self.unpin(store);
        return store.writeNext(entries);
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

    pub fn warm(self: *World, key: Key) !void {
        if (self.options.shard.cache == null) return;
        const size = (try self.valueSize(key)) orelse return;
        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);
        _ = try self.get(key, buffer);
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

        var distinct: [max_distinct_regions]Region = undefined;
        var region_count: usize = 0;
        for (requests) |request| {
            const found = request.key.region();
            const seen = for (distinct[0..region_count]) |existing| {
                if (std.meta.eql(existing, found)) break true;
            } else false;
            if (seen) continue;
            if (region_count == distinct.len) return error.TooManyKeys;
            distinct[region_count] = found;
            region_count += 1;
        }

        var sub_requests: [store_module.max_batch_keys]ReadRequest = undefined;
        var sub_indices: [store_module.max_batch_keys]usize = undefined;
        var sub_results: [store_module.max_batch_keys]ReadResult = undefined;

        for (distinct[0..region_count]) |region| {
            const store = (try self.acquire(region, false)) orelse continue;
            defer self.unpin(store);

            var next: usize = 0;
            while (next < requests.len) {
                var sub_count: usize = 0;
                while (next < requests.len and sub_count < sub_requests.len) : (next += 1) {
                    if (!std.meta.eql(requests[next].key.region(), region)) continue;
                    sub_requests[sub_count] = requests[next];
                    sub_indices[sub_count] = next;
                    sub_count += 1;
                }
                if (sub_count == 0) break;
                try store.getMany(sub_requests[0..sub_count], sub_results[0..sub_count]);
                for (sub_indices[0..sub_count], sub_results[0..sub_count]) |i, result| results[i] = result;
            }
        }
    }

    pub fn regions(self: *World, allocator: std.mem.Allocator) ![]Region {
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed or self.closing) return error.Closed;
        }
        var list: std.ArrayListUnmanaged(Region) = .empty;
        errdefer list.deinit(allocator);
        const dir = try self.directory.dir.openDir(self.io, ".", .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (parseRegionName(entry.name)) |region| try list.append(allocator, region);
        }
        const result = try list.toOwnedSlice(allocator);
        std.mem.sort(Region, result, {}, regionLessThan);
        return result;
    }

    pub fn keys(self: *World, region: Region, allocator: std.mem.Allocator, filter: KeyFilter) ![]Key {
        const store = (try self.acquire(region, false)) orelse return &.{};
        defer self.unpin(store);
        return store.keys(allocator, filter);
    }

    pub const max_range_regions = 1024;

    pub fn keysInRange(self: *World, allocator: std.mem.Allocator, dimension: i32, filter: KeyFilter) ![]Key {
        const min_x = @divFloor(filter.min_chunk_x, 32);
        const max_x = @divFloor(filter.max_chunk_x, 32);
        const min_z = @divFloor(filter.min_chunk_z, 32);
        const max_z = @divFloor(filter.max_chunk_z, 32);
        if (max_x < min_x or max_z < min_z) return &.{};
        const width = @as(i64, max_x) - min_x + 1;
        const depth = @as(i64, max_z) - min_z + 1;
        if (width * depth > max_range_regions) return error.RangeTooLarge;

        var list: std.ArrayListUnmanaged(Key) = .empty;
        errdefer list.deinit(allocator);
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            var z = min_z;
            while (z <= max_z) : (z += 1) {
                const found = try self.keys(.{ .dimension = dimension, .x = x, .z = z }, allocator, filter);
                defer allocator.free(found);
                try list.appendSlice(allocator, found);
            }
        }
        const result = try list.toOwnedSlice(allocator);
        std.mem.sort(Key, result, {}, key_format.keyLessThan);
        return result;
    }

    fn parseRegionName(name: []const u8) ?Region {
        if (name.len != 33 or name[8] != '-' or name[17] != '-' or !std.mem.endsWith(u8, name, ".region")) return null;
        var parts: [3]i32 = undefined;
        for (&parts, 0..) |*part, i| {
            const hex = name[i * 9 ..][0..8];
            part.* = @bitCast(std.fmt.parseInt(u32, hex, 16) catch return null);
        }
        return .{ .dimension = parts[0], .x = parts[1], .z = parts[2] };
    }

    fn regionLessThan(_: void, a: Region, b: Region) bool {
        if (a.dimension != b.dimension) return a.dimension < b.dimension;
        if (a.x != b.x) return a.x < b.x;
        return a.z < b.z;
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
            if (!create and self.knownMissing(region)) return null;
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

    fn missingSlot(region: Region) usize {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, region);
        return hasher.final() % 256;
    }

    fn knownMissing(self: *World, region: Region) bool {
        const found = self.missing[missingSlot(region)] orelse return false;
        return std.meta.eql(found, region);
    }

    fn load(self: *World, region: Region, create: bool) !?*Store {
        var name_buffer: [40]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{x:0>8}-{x:0>8}-{x:0>8}.region", .{
            @as(u32, @bitCast(region.dimension)),
            @as(u32, @bitCast(region.x)),
            @as(u32, @bitCast(region.z)),
        });
        const missing = &self.missing[missingSlot(region)];
        if (create and self.knownMissing(region)) missing.* = null;

        var created = false;
        const dir = self.directory.dir.openDir(self.io, name, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            if (!create) {
                missing.* = region;
                return null;
            }
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
