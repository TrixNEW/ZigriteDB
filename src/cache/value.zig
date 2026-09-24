const std = @import("std");

const Key = @import("../format/key.zig").Key;
const Stats = @import("../stats.zig").Stats;

pub const Options = struct {
    bytes: usize = 0,
    shards: usize = 16,
};

pub const entry_overhead = 64;

pub const Cache = struct {
    allocator: std.mem.Allocator,
    shards: []Shard,
    stats: ?*Stats = null,

    const Slot = struct {
        key: Key,
        batch_id: u64,
        value: []u8,
        referenced: bool = false,
    };

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        map: std.AutoHashMapUnmanaged(Key, u32) = .empty,
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        hand: usize = 0,
        used: usize = 0,
        capacity: usize,

        fn cost(value_len: usize) usize {
            return value_len + entry_overhead;
        }

        fn removeAt(self: *Shard, allocator: std.mem.Allocator, index: usize) void {
            const slot = self.slots.items[index];
            allocator.free(slot.value);
            self.used -= cost(slot.value.len);
            _ = self.map.remove(slot.key);
            _ = self.slots.swapRemove(index);
            if (index < self.slots.items.len) self.map.getPtr(self.slots.items[index].key).?.* = @intCast(index);
        }
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Cache {
        if (options.shards == 0 or options.shards > 1024) return error.InvalidCacheShards;
        const shards = try allocator.alloc(Shard, options.shards);
        for (shards) |*shard| shard.* = .{ .capacity = options.bytes / options.shards };
        return .{ .allocator = allocator, .shards = shards };
    }

    pub fn deinit(self: *Cache) void {
        for (self.shards) |*shard| {
            for (shard.slots.items) |slot| self.allocator.free(slot.value);
            shard.slots.deinit(self.allocator);
            shard.map.deinit(self.allocator);
        }
        self.allocator.free(self.shards);
        self.* = undefined;
    }

    fn shardFor(self: *Cache, key: Key) *Shard {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, key);
        return &self.shards[hasher.final() % self.shards.len];
    }

    pub fn get(self: *Cache, io: std.Io, key: Key, batch_id: u64, output: []u8) ?[]const u8 {
        const shard = self.shardFor(key);
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        const hit: ?[]const u8 = blk: {
            const index = shard.map.get(key) orelse break :blk null;
            const slot = &shard.slots.items[index];
            if (slot.batch_id != batch_id or output.len < slot.value.len) break :blk null;
            slot.referenced = true;
            @memcpy(output[0..slot.value.len], slot.value);
            break :blk output[0..slot.value.len];
        };

        if (self.stats) |s| _ = (if (hit != null) &s.cache_hits else &s.cache_misses).fetchAdd(1, .monotonic);
        return hit;
    }

    pub fn put(self: *Cache, io: std.Io, key: Key, batch_id: u64, value: []const u8) void {
        const shard = self.shardFor(key);
        const needed = Shard.cost(value.len);
        if (needed > shard.capacity) return;

        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.map.get(key)) |index| {
            if (shard.slots.items[index].batch_id >= batch_id) return;
            shard.removeAt(self.allocator, index);
        }

        while (shard.used + needed > shard.capacity) {
            if (shard.hand >= shard.slots.items.len) shard.hand = 0;
            const slot = &shard.slots.items[shard.hand];
            if (slot.referenced) {
                slot.referenced = false;
                shard.hand += 1;
                continue;
            }
            shard.removeAt(self.allocator, shard.hand);
            if (self.stats) |s| _ = s.cache_evictions.fetchAdd(1, .monotonic);
        }

        const copy = self.allocator.dupe(u8, value) catch return;
        shard.slots.append(self.allocator, .{ .key = key, .batch_id = batch_id, .value = copy }) catch {
            self.allocator.free(copy);
            return;
        };
        shard.map.put(self.allocator, key, @intCast(shard.slots.items.len - 1)) catch {
            _ = shard.slots.pop();
            self.allocator.free(copy);
            return;
        };
        shard.used += needed;
    }
};
