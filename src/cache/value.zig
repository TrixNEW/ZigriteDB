const std = @import("std");

const Key = @import("../format/key.zig").Key;
const Stats = @import("../stats.zig").Stats;

pub const Options = struct {
    bytes: usize = 0,
    shards: usize = 16,
};

pub const entry_overhead = 64;

/// Memory charged for caching a value of `len` bytes.
pub fn cost(len: usize) usize {
    return sizeClass(len) + entry_overhead;
}

// Power-of-two buffers let an evicted value's buffer be reused by the next one.
fn sizeClass(len: usize) usize {
    return std.math.ceilPowerOfTwo(usize, @max(len, 16)) catch len;
}

pub const Cache = struct {
    allocator: std.mem.Allocator,
    shards: []Shard,
    stats: ?*Stats = null,

    const Slot = struct {
        key: Key,
        batch_id: u64,
        buffer: []u8,
        len: usize,
        referenced: bool = false,
    };

    const seen_len = 1024;

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        map: std.AutoHashMapUnmanaged(Key, u32) = .empty,
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        hand: usize = 0,
        used: usize = 0,
        capacity: usize,
        // Recent misses; when full, a key is only admitted on its second miss.
        seen: [seen_len]u32 = @splat(0),

        fn take(self: *Shard, index: usize) []u8 {
            const slot = self.slots.items[index];
            self.used -= slot.buffer.len + entry_overhead;
            _ = self.map.remove(slot.key);
            _ = self.slots.swapRemove(index);
            if (index < self.slots.items.len) self.map.getPtr(self.slots.items[index].key).?.* = @intCast(index);
            return slot.buffer;
        }

        fn admit(self: *Shard, hash: u64) bool {
            const tag: u32 = @truncate(hash >> 32 | 1);
            const i: usize = @intCast((hash >> 16) % seen_len);
            if (self.seen[i] == tag) return true;
            self.seen[i] = tag;
            return false;
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
            for (shard.slots.items) |slot| self.allocator.free(slot.buffer);
            shard.slots.deinit(self.allocator);
            shard.map.deinit(self.allocator);
        }
        self.allocator.free(self.shards);
        self.* = undefined;
    }

    fn hashKey(key: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, key);
        return hasher.final();
    }

    pub fn get(self: *Cache, io: std.Io, key: Key, batch_id: u64, output: []u8) ?[]const u8 {
        const shard = &self.shards[hashKey(key) % self.shards.len];
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        const hit: ?[]const u8 = blk: {
            const index = shard.map.get(key) orelse break :blk null;
            const slot = &shard.slots.items[index];
            if (slot.batch_id != batch_id or output.len < slot.len) break :blk null;
            slot.referenced = true;
            @memcpy(output[0..slot.len], slot.buffer[0..slot.len]);
            break :blk output[0..slot.len];
        };

        if (self.stats) |s| _ = (if (hit != null) &s.cache_hits else &s.cache_misses).fetchAdd(1, .monotonic);
        return hit;
    }

    pub fn put(self: *Cache, io: std.Io, key: Key, batch_id: u64, value: []const u8) void {
        const hash = hashKey(key);
        const shard = &self.shards[hash % self.shards.len];
        const size = sizeClass(value.len);
        if (size + entry_overhead > shard.capacity) return;

        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        var reuse: ?[]u8 = null;
        if (shard.map.get(key)) |index| {
            const slot = &shard.slots.items[index];
            if (slot.batch_id >= batch_id) return;
            if (slot.buffer.len == size) {
                @memcpy(slot.buffer[0..value.len], value);
                slot.batch_id = batch_id;
                slot.len = value.len;
                slot.referenced = true;
                return;
            }
            self.allocator.free(shard.take(index));
        } else if (shard.used + size + entry_overhead > shard.capacity and !shard.admit(hash)) return;

        while (shard.used + size + entry_overhead > shard.capacity) {
            if (shard.hand >= shard.slots.items.len) shard.hand = 0;
            const slot = &shard.slots.items[shard.hand];
            if (slot.referenced) {
                slot.referenced = false;
                shard.hand += 1;
                continue;
            }
            const buffer = shard.take(shard.hand);
            if (reuse == null and buffer.len == size) reuse = buffer else self.allocator.free(buffer);
            if (self.stats) |s| _ = s.cache_evictions.fetchAdd(1, .monotonic);
        }

        const buffer = reuse orelse self.allocator.alloc(u8, size) catch return;
        shard.slots.ensureUnusedCapacity(self.allocator, 1) catch return self.allocator.free(buffer);
        shard.map.put(self.allocator, key, @intCast(shard.slots.items.len)) catch return self.allocator.free(buffer);
        @memcpy(buffer[0..value.len], value);
        shard.slots.appendAssumeCapacity(.{ .key = key, .batch_id = batch_id, .buffer = buffer, .len = value.len });
        shard.used += size + entry_overhead;
    }
};
