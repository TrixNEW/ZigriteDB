const std = @import("std");

const lock = @import("../lock.zig");

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

// Hashed once per call: the low bits pick a shard and the high bits index it.
fn hashKey(key: Key) u64 {
    const words = [3]u64{
        @as(u64, @as(u32, @bitCast(key.chunk_x))) | @as(u64, @as(u32, @bitCast(key.chunk_z))) << 32,
        @as(u64, @as(u32, @bitCast(key.dimension))) | @as(u64, @as(u32, @bitCast(key.subchunk_y))) << 32,
        @intFromEnum(key.component),
    };
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&words));
}

const Context = struct {
    pub fn hash(_: Context, key: Key) u32 {
        return @truncate(hashKey(key) >> 32);
    }

    pub fn eql(_: Context, a: Key, b: Key, _: usize) bool {
        return std.meta.eql(a, b);
    }
};

// Hands the map the hash the caller already has.
const Hashed = struct {
    bits: u32,

    fn of(full: u64) Hashed {
        return .{ .bits = @truncate(full >> 32) };
    }

    pub fn hash(self: Hashed, _: Key) u32 {
        return self.bits;
    }

    pub fn eql(_: Hashed, a: Key, b: Key, _: usize) bool {
        return std.meta.eql(a, b);
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    shards: []Shard,
    stats: ?*Stats = null,

    const Slot = struct {
        hash: u64,
        batch_id: u64,
        buffer: []u8,
        len: usize,
        referenced: bool = false,
    };

    const counts_len = 4096;

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        // Array hash maps delete without tombstones, which constant evictions would pile up.
        slots: std.ArrayHashMapUnmanaged(Key, Slot, Context, false) = .empty,
        hand: usize = 0,
        used: usize = 0,
        capacity: usize,
        // Rough, decaying read counts: a full shard only takes a key read more often than
        // the one it would evict.
        counts: [counts_len]u8 = @splat(0),
        touches: usize = 0,

        fn take(self: *Shard, index: usize) []u8 {
            const slot = self.slots.values()[index];
            self.used -= slot.buffer.len + entry_overhead;
            self.slots.swapRemoveAt(index);
            return slot.buffer;
        }

        fn touch(self: *Shard, hash: u64) void {
            const count = &self.counts[@intCast((hash >> 16) % counts_len)];
            if (count.* < 15) count.* += 1;
            self.touches += 1;
            if (self.touches < counts_len * 8) return;
            self.touches = 0;
            for (&self.counts) |*value| value.* >>= 1;
        }

        fn frequency(self: *const Shard, hash: u64) u8 {
            return self.counts[@intCast((hash >> 16) % counts_len)];
        }

        /// The slot the clock would evict next, clearing reference bits on the way.
        fn victim(self: *Shard) usize {
            const slots = self.slots.values();
            while (true) {
                if (self.hand >= slots.len) self.hand = 0;
                const slot = &slots[self.hand];
                if (!slot.referenced) return self.hand;
                slot.referenced = false;
                self.hand += 1;
            }
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
            for (shard.slots.values()) |slot| self.allocator.free(slot.buffer);
            shard.slots.deinit(self.allocator);
        }
        self.allocator.free(self.shards);
        self.* = undefined;
    }

    pub fn get(self: *Cache, io: std.Io, key: Key, batch_id: u64, output: []u8) ?[]const u8 {
        const hash = hashKey(key);
        const shard = &self.shards[hash % self.shards.len];
        lock.lockUncancelable(&shard.mutex, io);
        defer shard.mutex.unlock(io);
        shard.touch(hash);

        const hit: ?[]const u8 = blk: {
            const slot = shard.slots.getPtrAdapted(key, Hashed.of(hash)) orelse break :blk null;
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

        lock.lockUncancelable(&shard.mutex, io);
        defer shard.mutex.unlock(io);

        var reuse: ?[]u8 = null;
        if (shard.slots.getIndexAdapted(key, Hashed.of(hash))) |index| {
            const slot = &shard.slots.values()[index];
            if (slot.batch_id >= batch_id) return;
            if (slot.buffer.len == size) {
                @memcpy(slot.buffer[0..value.len], value);
                slot.batch_id = batch_id;
                slot.len = value.len;
                slot.referenced = true;
                return;
            }
            self.allocator.free(shard.take(index));
        } else if (shard.used + size + entry_overhead > shard.capacity) {
            if (shard.frequency(hash) <= shard.frequency(shard.slots.values()[shard.victim()].hash)) return;
        }

        while (shard.used + size + entry_overhead > shard.capacity) {
            const buffer = shard.take(shard.victim());
            if (reuse == null and buffer.len == size) reuse = buffer else self.allocator.free(buffer);
            if (self.stats) |s| _ = s.cache_evictions.fetchAdd(1, .monotonic);
        }

        const buffer = reuse orelse self.allocator.alloc(u8, size) catch return;
        const entry = shard.slots.getOrPutAdapted(self.allocator, key, Hashed.of(hash)) catch return self.allocator.free(buffer);
        entry.key_ptr.* = key;
        @memcpy(buffer[0..value.len], value);
        entry.value_ptr.* = .{ .hash = hash, .batch_id = batch_id, .buffer = buffer, .len = value.len };
        shard.used += size + entry_overhead;
    }
};
