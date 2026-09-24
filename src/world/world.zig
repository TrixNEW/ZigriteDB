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
    clock: u64 = 0,
    positions: std.AutoHashMapUnmanaged(Region, u32) = .empty,
    loads: usize = 0,

    const Slot = struct {
        region: Region,
        store: *Store,
        users: usize = 0,
        last_used: u64 = 0,
        loading: bool = false,
        evicting: ?Region = null,
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !World {
        if (options.max_open_shards == 0 or options.max_open_shards > 1024) return error.InvalidShardLimit;
        try options.shard.validate();
        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();
        const slots = try allocator.alloc(Slot, options.max_open_shards);
        errdefer allocator.free(slots);

        var result: World = .{ .allocator = allocator, .io = io, .directory = directory, .options = options, .slots = slots };
        try result.positions.ensureTotalCapacity(allocator, @intCast(options.max_open_shards));
        errdefer result.positions.deinit(allocator);
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

        var start: usize = 0;
        while (start < requests.len) : (start += max_read_batch) {
            const end = @min(requests.len, start + max_read_batch);
            try self.getManyChunk(requests[start..end], results[start..end]);
        }
    }

    fn getManyChunk(self: *World, requests: []const ReadRequest, results: []ReadResult) !void {
        var order: [max_read_batch]u16 = undefined;
        for (order[0..requests.len], 0..) |*value, i| value.* = @intCast(i);
        std.sort.pdq(u16, order[0..requests.len], requests, requestRegionLessThan);

        var sub_requests: [store_module.max_batch_keys]ReadRequest = undefined;
        var sub_results: [store_module.max_batch_keys]ReadResult = undefined;

        var run: usize = 0;
        while (run < requests.len) {
            const region = requests[order[run]].key.region();
            var run_end = run + 1;
            while (run_end < requests.len and std.meta.eql(requests[order[run_end]].key.region(), region)) run_end += 1;
            defer run = run_end;

            const store = (try self.acquire(region, false)) orelse continue;
            defer self.unpin(store);

            var next = run;
            while (next < run_end) {
                const count = @min(run_end - next, sub_requests.len);
                const indices = order[next..][0..count];
                for (indices, sub_requests[0..count]) |i, *request| request.* = requests[i];
                try store.getMany(sub_requests[0..count], sub_results[0..count]);
                for (indices, sub_results[0..count]) |i, result| results[i] = result;
                next += count;
            }
        }
    }

    fn requestRegionLessThan(requests: []const ReadRequest, a: u16, b: u16) bool {
        return regionLessThan({}, requests[a].key.region(), requests[b].key.region());
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
    pub const max_read_batch = 256;

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
        var count: usize = 0;
        for (self.slots[0..self.count]) |*slot| {
            if (slot.loading) continue;
            slot.users += 1;
            stores[count] = slot.store;
            count += 1;
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
            if (self.busy(region)) {
                try self.changed.wait(self.io, &self.mutex);
                continue;
            }
            if (self.find(region)) |i| {
                self.clock += 1;
                self.slots[i].last_used = self.clock;
                self.slots[i].users += 1;
                return self.slots[i].store;
            }
            if (!create and self.knownMissing(region)) return null;
            if (self.count < self.slots.len or self.hasIdle()) return self.load(region, create);
            try self.changed.wait(self.io, &self.mutex);
        }
    }

    fn find(self: *World, region: Region) ?usize {
        const i = self.positions.get(region) orelse return null;
        return i;
    }

    fn busy(self: *World, region: Region) bool {
        if (self.loads == 0) return false;
        for (self.slots[0..self.count]) |slot| {
            if (!slot.loading) continue;
            if (std.meta.eql(slot.region, region)) return true;
            if (slot.evicting) |evicting| if (std.meta.eql(evicting, region)) return true;
        }
        return false;
    }

    fn unpin(self: *World, store: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = &self.slots[self.find(store.region).?];
        std.debug.assert(!slot.loading and slot.store == store and slot.users != 0);
        slot.users -= 1;
        self.changed.broadcast(self.io);
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
        if (create and self.knownMissing(region)) self.missing[missingSlot(region)] = null;

        var victim: ?*Store = null;
        var evicting: ?Region = null;
        if (self.count == self.slots.len) {
            const i = self.idleIndex().?;
            victim = self.slots[i].store;
            evicting = self.slots[i].region;
            self.removeAt(i);
        }
        self.clock += 1;
        self.slots[self.count] = .{ .region = region, .store = undefined, .users = 1, .last_used = self.clock, .loading = true, .evicting = evicting };
        self.positions.putAssumeCapacity(region, @intCast(self.count));
        self.count += 1;
        self.loads += 1;

        self.mutex.unlock(self.io);
        const opened = self.openRegion(region, create, victim);
        self.mutex.lockUncancelable(self.io);
        defer self.changed.broadcast(self.io);
        self.loads -= 1;

        const i = self.find(region).?;
        const store = (opened catch |err| {
            self.removeAt(i);
            return err;
        }) orelse {
            self.removeAt(i);
            self.missing[missingSlot(region)] = region;
            return null;
        };
        self.slots[i].store = store;
        self.slots[i].loading = false;
        self.slots[i].evicting = null;
        return store;
    }

    fn removeAt(self: *World, i: usize) void {
        _ = self.positions.remove(self.slots[i].region);
        self.count -= 1;
        if (i == self.count) return;
        self.slots[i] = self.slots[self.count];
        self.positions.getPtr(self.slots[i].region).?.* = @intCast(i);
    }

    fn idleIndex(self: *World) ?usize {
        var oldest: ?usize = null;
        for (self.slots[0..self.count], 0..) |slot, i| {
            if (slot.users != 0) continue;
            if (oldest == null or slot.last_used < self.slots[oldest.?].last_used) oldest = i;
        }
        return oldest;
    }

    fn openRegion(self: *World, region: Region, create: bool, victim: ?*Store) !?*Store {
        if (victim) |store| {
            defer self.allocator.destroy(store);
            try store.close();
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
        store.* = if (created)
            try Store.create(self.allocator, self.io, dir, region, self.options.shard)
        else
            Store.open(self.allocator, self.io, dir, self.options.shard) catch |err| blk: {
                if ((err != error.MissingManifest and err != error.NeedsRecovery) or !create) return err;
                break :blk Store.create(self.allocator, self.io, dir, region, self.options.shard) catch |create_err| {
                    if (create_err == error.DirectoryNotEmpty) return err;
                    return create_err;
                };
            };
        errdefer store.deinit();
        if (!std.meta.eql(store.shard.generation.index.region, region)) return error.RegionMismatch;
        if (created) try self.directory.syncEntries();
        return store;
    }

    fn evict(self: *World) !void {
        const i = self.idleIndex().?;
        const store = self.slots[i].store;
        self.removeAt(i);
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
        self.positions.deinit(self.allocator);
        self.directory.deinit();
        self.count = 0;
        self.closed = true;
        self.changed.broadcast(self.io);
    }
};
