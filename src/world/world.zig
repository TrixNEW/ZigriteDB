const std = @import("std");

const lock = @import("../lock.zig");

const write_module = @import("../batch/write.zig");
const WriteBatch = write_module.WriteBatch;
const crc = @import("../format/crc.zig");
const key_format = @import("../format/key.zig");
const Key = key_format.Key;
const KeyFilter = key_format.KeyFilter;
const Region = key_format.Region;
const manifest = @import("../format/manifest.zig");
const store_module = @import("../region/store.zig");
const Store = store_module.Store;
const AppendResult = store_module.AppendResult;
const Directory = @import("../storage/directory.zig").Directory;
const File = @import("../io/file.zig").File;

const cache_module = @import("../cache/value.zig");

pub const Options = struct {
    max_open_regions: usize = 64,
    region: store_module.Options = .{},
    cache: cache_module.Options = .{},
};

pub const format_file = "ZIGRITE";
pub const format_version = 2;

pub const Compactor = struct {
    context: *anyopaque,
    submit: *const fn (context: *anyopaque, region: Region) void,
};

pub const ReadRequest = store_module.ReadRequest;
pub const ReadStatus = store_module.ReadStatus;
pub const ReadResult = store_module.ReadResult;
pub const ChunkRecord = store_module.ChunkRecord;
pub const ChunkResult = store_module.ChunkResult;

pub const World = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: Directory,
    options: Options,
    slots: []Slot,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
    // Held shared to pin an open region; changes to the slot table also hold `mutex`.
    table: std.Io.RwLock = .init,
    closed: bool = false,
    closing: bool = false,
    changed: std.Io.Condition = .init,
    missing: [256]?Region = .{null} ** 256,
    positions: std.AutoHashMapUnmanaged(Region, u32) = .empty,
    loads: usize = 0,
    hand: usize = 0,
    compactor: ?Compactor = null,
    waiters: std.atomic.Value(usize) = .init(0),
    aux_mutex: std.Io.Mutex = .init,

    const Opened = struct {
        store: Store,
        users: std.atomic.Value(usize) = .init(0),
    };

    const Slot = struct {
        region: Region,
        opened: *Opened,
        referenced: std.atomic.Value(bool) = .init(true),
        loading: bool = false,
        evicting: ?Region = null,

        fn idle(self: *const Slot) bool {
            return !self.loading and self.opened.users.load(.seq_cst) == 0;
        }
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: Options) !World {
        if (options.max_open_regions == 0 or options.max_open_regions > 1024) return error.InvalidRegionLimit;
        try options.region.validate();
        var directory = try Directory.init(dir, io);
        errdefer directory.deinit();
        // Region directories from a crash may not be durable yet.
        try directory.syncEntries();
        try checkFormat(&directory);
        const slots = try allocator.alloc(Slot, options.max_open_regions);
        errdefer allocator.free(slots);

        var result: World = .{ .allocator = allocator, .io = io, .directory = directory, .options = options, .slots = slots };
        try result.positions.ensureTotalCapacity(allocator, @intCast(options.max_open_regions));
        errdefer result.positions.deinit(allocator);
        if (options.cache.bytes > 0) {
            const cache = try allocator.create(cache_module.Cache);
            errdefer allocator.destroy(cache);
            cache.* = try cache_module.Cache.init(allocator, options.cache);
            cache.stats = options.region.stats;
            result.options.region.cache = cache;
        }
        return result;
    }

    pub fn write(self: *World, batch: WriteBatch) !AppendResult {
        const size = try batch.validate();
        if (size > self.options.region.batch_buffer_size) return error.BufferTooSmall;
        const store = (try self.acquire(batch.region(), true)).?;
        defer self.unpin(store);
        defer self.suggest(store);
        return store.write(batch);
    }

    /// Durable on return.
    pub fn writeGroup(self: *World, batches: []const WriteBatch) !AppendResult {
        const size = try write_module.validateGroup(batches);
        if (size > self.options.region.batch_buffer_size) return error.BufferTooSmall;
        const store = (try self.acquire(batches[0].region(), true)).?;
        defer self.unpin(store);
        defer self.suggest(store);
        return store.writeGroup(batches);
    }

    fn suggest(self: *World, store: *Store) void {
        const compactor = self.compactor orelse return;
        if (store.wantsCompaction()) compactor.submit(compactor.context, store.region);
    }

    pub fn get(self: *World, key: Key, output: []u8) !?[]const u8 {
        try key.validate();
        const store = (try self.acquire(key.region(), false)) orelse return null;
        defer self.unpin(store);
        return store.get(key, output);
    }

    pub fn warm(self: *World, key: Key) !void {
        if (self.options.region.cache == null) return;
        const size = (try self.valueSize(key)) orelse return;
        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);
        _ = try self.get(key, buffer);
    }

    pub fn getSized(self: *World, key: Key, output: []u8, required: *usize) !?[]const u8 {
        required.* = 0;
        try key.validate();
        const store = (try self.acquire(key.region(), false)) orelse return null;
        defer self.unpin(store);
        return store.getSized(key, output, required);
    }

    pub fn getMany(self: *World, requests: []const ReadRequest, results: []ReadResult) !void {
        std.debug.assert(requests.len == results.len);
        for (requests) |request| try request.key.validate();
        @memset(results, .{});
        if (requests.len == 0) return;

        var start: usize = 0;
        while (start < requests.len) : (start += read_chunk) {
            const end = @min(requests.len, start + read_chunk);
            try self.getManyChunk(requests[start..end], results[start..end]);
        }
    }

    const read_chunk = 32;

    pub fn getChunk(self: *World, dimension: i32, chunk_x: i32, chunk_z: i32, buffer: []u8, records: []ChunkRecord, result: *ChunkResult) !void {
        result.* = .{ .count = 0, .required = 0 };
        const region: Region = .{ .dimension = dimension, .x = chunk_x >> 5, .z = chunk_z >> 5 };
        const store = (try self.acquire(region, false)) orelse return;
        defer self.unpin(store);
        return store.getChunk(chunk_x, chunk_z, buffer, records, result);
    }

    fn getManyChunk(self: *World, requests: []const ReadRequest, results: []ReadResult) !void {
        const first = requests[0].key.region();
        for (requests[1..]) |request| {
            if (!std.meta.eql(request.key.region(), first)) break;
        } else {
            const store = (try self.acquire(first, false)) orelse return;
            defer self.unpin(store);
            return store.getMany(requests, results);
        }

        var order: [read_chunk]u16 = undefined;
        for (order[0..requests.len], 0..) |*value, i| value.* = @intCast(i);
        std.sort.pdq(u16, order[0..requests.len], requests, requestRegionLessThan);

        var sub_requests: [read_chunk]ReadRequest = undefined;
        var sub_results: [read_chunk]ReadResult = undefined;

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
            try lock.lock(&self.mutex, self.io);
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

    pub fn parseRegionName(name: []const u8) ?Region {
        if (name.len != 33 or name[8] != '-' or name[17] != '-' or !std.mem.endsWith(u8, name, ".region")) return null;
        var parts: [3]i32 = undefined;
        for (&parts, 0..) |*part, i| {
            const hex = name[i * 9 ..][0..8];
            part.* = @bitCast(std.fmt.parseInt(u32, hex, 16) catch return null);
        }
        return .{ .dimension = parts[0], .x = parts[1], .z = parts[2] };
    }

    /// Refuses format 1 worlds.
    fn checkFormat(directory: *Directory) !void {
        var bytes: [12]u8 = undefined;
        const io = directory.io;
        if (directory.dir.openFile(io, format_file, .{})) |file| {
            defer file.close(io);
            const device: File = .{ .handle = file, .io = io };
            if (try device.length() != bytes.len) return error.InvalidFormatFile;
            try device.readExact(&bytes, 0);
            if (!std.mem.eql(u8, bytes[0..4], "ZGWD") or std.mem.readInt(u32, bytes[8..12], .little) != crc.hash(bytes[0..8])) return error.InvalidFormatFile;
            const found = std.mem.readInt(u16, bytes[4..6], .little);
            if (found < format_version) return error.NeedsMigration;
            if (found > format_version) return error.UnsupportedVersion;
            return;
        } else |err| if (err != error.FileNotFound) return err;

        // No marker yet: check a region's manifest.
        var iterator = directory.dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .directory or parseRegionName(entry.name) == null) continue;
            const region_dir = directory.dir.openDir(io, entry.name, .{ .follow_symlinks = false }) catch continue;
            defer region_dir.close(io);
            const file = region_dir.openFile(io, "MANIFEST", .{}) catch continue;
            defer file.close(io);
            var head: [6]u8 = undefined;
            (File{ .handle = file, .io = io }).readExact(&head, 0) catch continue;
            const found = manifest.peekVersion(&head) orelse continue;
            if (found < format_version) return error.NeedsMigration;
            if (found > format_version) return error.UnsupportedVersion;
        }
        @memcpy(bytes[0..4], "ZGWD");
        std.mem.writeInt(u16, bytes[4..6], format_version, .little);
        std.mem.writeInt(u16, bytes[6..8], 0, .little);
        std.mem.writeInt(u32, bytes[8..12], crc.hash(bytes[0..8]), .little);
        const file = try directory.dir.createFile(io, format_file ++ ".tmp", .{ .truncate = true });
        {
            defer file.close(io);
            const device: File = .{ .handle = file, .io = io };
            try device.writeAll(&bytes, 0);
            try device.sync();
        }
        try directory.dir.rename(format_file ++ ".tmp", directory.dir, format_file, io);
        try directory.syncEntries();
    }

    pub fn regionName(buffer: *[40]u8, region: Region) []const u8 {
        return std.fmt.bufPrint(buffer, "{x:0>8}-{x:0>8}-{x:0>8}.region", .{
            @as(u32, @bitCast(region.dimension)),
            @as(u32, @bitCast(region.x)),
            @as(u32, @bitCast(region.z)),
        }) catch unreachable;
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
        try key.validate();
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
        try lock.lock(&self.mutex, self.io);
        if (self.closed or self.closing) {
            self.mutex.unlock(self.io);
            return error.Closed;
        }
        var count: usize = 0;
        for (self.slots[0..self.count]) |*slot| {
            if (slot.loading) continue;
            _ = slot.opened.users.fetchAdd(1, .seq_cst);
            stores[count] = &slot.opened.store;
            count += 1;
        }
        self.mutex.unlock(self.io);
        defer for (stores[0..count]) |store| self.unpin(store);

        // Regions are separate files, so their fsyncs can overlap.
        var failures: [1024]?anyerror = undefined;
        var group: std.Io.Group = .init;
        for (stores[0..count], failures[0..count]) |store, *failure| group.async(self.io, flushStore, .{ store, failure });
        try group.await(self.io);
        for (failures[0..count]) |failure| if (failure) |err| return err;
    }

    fn flushStore(store: *Store, failure: *?anyerror) void {
        store.flush() catch |err| {
            failure.* = err;
            return;
        };
        failure.* = null;
    }

    pub fn close(self: *World) !void {
        lock.lockUncancelable(&self.mutex, self.io);
        defer self.mutex.unlock(self.io);
        while (self.closing and !self.closed) self.waitUncancelable();
        if (self.closed) return;
        self.startClosing();
        while (self.inUse()) self.waitUnused();
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
        lock.lockUncancelable(&self.mutex, self.io);
        defer self.mutex.unlock(self.io);
        while (self.closing and !self.closed) self.waitUncancelable();
        if (self.closed) return;
        self.startClosing();
        while (self.inUse()) self.waitUnused();
        for (self.slots[0..self.count]) |slot| {
            slot.opened.store.deinit();
            self.allocator.destroy(slot.opened);
        }
        self.release();
    }

    fn acquire(self: *World, region: Region, create: bool) !?*Store {
        if (self.pinOpen(region)) |store| return store;
        try lock.lock(&self.mutex, self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            if (self.closed or self.closing) return error.Closed;
            if (self.busy(region)) {
                try self.wait();
                continue;
            }
            if (self.find(region)) |i| return self.pin(&self.slots[i]);
            if (!create and self.knownMissing(region)) return null;
            if (self.count < self.slots.len or self.hasIdle()) return self.load(region, create) catch |err| switch (err) {
                // A reader pinned the last idle region after `hasIdle`.
                error.NoIdleSlot => {
                    try self.waitIdle();
                    continue;
                },
                else => return err,
            };
            try self.waitIdle();
        }
    }

    fn pinOpen(self: *World, region: Region) ?*Store {
        self.table.lockSharedUncancelable(self.io);
        defer self.table.unlockShared(self.io);
        if (self.closing) return null;
        const i = self.positions.get(region) orelse return null;
        if (self.slots[i].loading) return null;
        return self.pin(&self.slots[i]);
    }

    fn pin(_: *World, slot: *Slot) *Store {
        _ = slot.opened.users.fetchAdd(1, .seq_cst);
        if (!slot.referenced.load(.monotonic)) slot.referenced.store(true, .monotonic);
        return &slot.opened.store;
    }

    fn unpin(self: *World, store: *Store) void {
        const opened: *Opened = @fieldParentPtr("store", store);
        _ = opened.users.fetchSub(1, .seq_cst);
        if (self.waiters.load(.seq_cst) == 0) return;
        lock.lockUncancelable(&self.mutex, self.io);
        defer self.mutex.unlock(self.io);
        self.changed.broadcast(self.io);
    }

    fn wait(self: *World) !void {
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        try self.changed.wait(self.io, &self.mutex);
    }

    fn waitUncancelable(self: *World) void {
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        self.changed.waitUncancelable(self.io, &self.mutex);
    }

    // Pins drop without `mutex`, so register as a waiter before checking them; either the check
    // sees the unpin or the unpin sees the waiter.
    fn waitIdle(self: *World) !void {
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        if (self.hasIdle()) return;
        try self.changed.wait(self.io, &self.mutex);
    }

    fn waitUnused(self: *World) void {
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        if (!self.inUse()) return;
        self.changed.waitUncancelable(self.io, &self.mutex);
    }

    fn startClosing(self: *World) void {
        self.table.lockUncancelable(self.io);
        defer self.table.unlock(self.io);
        self.closing = true;
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

    fn hasIdle(self: *World) bool {
        for (self.slots[0..self.count]) |*slot| {
            if (slot.idle()) return true;
        }
        return false;
    }

    fn inUse(self: *World) bool {
        for (self.slots[0..self.count]) |*slot| {
            if (!slot.idle()) return true;
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

        var victim: ?*Opened = null;
        var evicting: ?Region = null;
        {
            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            if (self.count == self.slots.len) {
                const i = self.idleIndex() orelse return error.NoIdleSlot;
                victim = self.slots[i].opened;
                evicting = self.slots[i].region;
                self.removeAt(i);
            }
            self.slots[self.count] = .{ .region = region, .opened = undefined, .loading = true, .evicting = evicting };
            self.positions.putAssumeCapacity(region, @intCast(self.count));
            self.count += 1;
        }
        self.loads += 1;

        self.mutex.unlock(self.io);
        const result = self.openRegion(region, create, victim);
        lock.lockUncancelable(&self.mutex, self.io);
        defer self.changed.broadcast(self.io);
        self.loads -= 1;

        self.table.lockUncancelable(self.io);
        defer self.table.unlock(self.io);
        const i = self.find(region).?;
        const opened = (result catch |err| {
            self.removeAt(i);
            return err;
        }) orelse {
            self.removeAt(i);
            self.missing[missingSlot(region)] = region;
            return null;
        };
        opened.users.store(1, .seq_cst);
        self.slots[i].opened = opened;
        self.slots[i].loading = false;
        self.slots[i].evicting = null;
        return &opened.store;
    }

    fn removeAt(self: *World, i: usize) void {
        _ = self.positions.remove(self.slots[i].region);
        self.count -= 1;
        if (i == self.count) return;
        self.slots[i] = self.slots[self.count];
        self.positions.getPtr(self.slots[i].region).?.* = @intCast(i);
    }

    /// Second chance: recently pinned regions are skipped once.
    fn idleIndex(self: *World) ?usize {
        for (0..2 * self.count) |step| {
            const i = (self.hand + step) % self.count;
            const slot = &self.slots[i];
            if (!slot.idle()) continue;
            if (slot.referenced.swap(false, .monotonic)) continue;
            self.hand = i + 1;
            return i;
        }
        return null;
    }

    fn openRegion(self: *World, region: Region, create: bool, victim: ?*Opened) !?*Opened {
        if (victim) |opened| {
            defer self.allocator.destroy(opened);
            try opened.store.close();
        }

        var name_buffer: [40]u8 = undefined;
        const name = regionName(&name_buffer, region);
        var created = false;
        const dir = self.directory.dir.openDir(self.io, name, .{ .follow_symlinks = false }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            if (!create) return null;
            try self.directory.dir.createDir(self.io, name, .default_dir);
            created = true;
            break :blk try self.directory.dir.openDir(self.io, name, .{ .follow_symlinks = false });
        };
        defer dir.close(self.io);
        const opened = try self.allocator.create(Opened);
        errdefer self.allocator.destroy(opened);
        opened.* = .{ .store = undefined };
        const store = &opened.store;
        store.* = if (created)
            try Store.create(self.allocator, self.io, dir, region, self.options.region)
        else
            Store.open(self.allocator, self.io, dir, self.options.region) catch |err| blk: {
                if ((err != error.MissingManifest and err != error.NeedsRecovery) or !create) return err;
                break :blk Store.create(self.allocator, self.io, dir, region, self.options.region) catch |create_err| {
                    if (create_err == error.DirectoryNotEmpty) return err;
                    return create_err;
                };
            };
        errdefer store.deinit();
        if (!store.region.eql(region)) return error.RegionMismatch;
        if (created) try self.directory.syncEntries();
        return opened;
    }

    fn evict(self: *World) !void {
        const opened = blk: {
            self.table.lockUncancelable(self.io);
            defer self.table.unlock(self.io);
            const i = self.idleIndex().?;
            const opened = self.slots[i].opened;
            self.removeAt(i);
            break :blk opened;
        };
        defer self.allocator.destroy(opened);
        try opened.store.close();
    }

    fn release(self: *World) void {
        if (self.options.region.cache) |cache| {
            cache.deinit();
            self.allocator.destroy(cache);
            self.options.region.cache = null;
        }
        self.table.lockUncancelable(self.io);
        defer self.table.unlock(self.io);
        self.allocator.free(self.slots);
        self.positions.deinit(self.allocator);
        self.directory.deinit();
        self.count = 0;
        self.closed = true;
        self.changed.broadcast(self.io);
    }
};
