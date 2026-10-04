const std = @import("std");

const frame = @import("../format/frame.zig");
const key_format = @import("../format/key.zig");
const Key = key_format.Key;
const KeyFilter = key_format.KeyFilter;
const Region = key_format.Region;
const record = @import("../format/record.zig");
const scan = @import("../recovery/scan.zig");
const Stats = @import("../stats.zig").Stats;

pub const max_segments = 255;
pub const max_segment_size = std.math.maxInt(u32);

pub const Location = struct {
    batch_id: u64,
    offset: u32,
    stored_len: u32,
    raw_len: u32,
    /// Only kept for skip_unchanged.
    fingerprint: u32,
    segment: u8,
    compression: record.Compression,

    pub fn recordLen(self: Location) usize {
        return @as(usize, self.stored_len) + record.overhead;
    }
};

pub fn fingerprint(compression: record.Compression, stored: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(@intFromEnum(compression), stored));
}

/// One chunk's sorted components; keys and locations share one allocation.
const Chunk = struct {
    data: ?[*]align(@alignOf(Location)) u8 = null,
    len: u16 = 0,
    capacity: u16 = 0,

    pub fn locations(self: Chunk) []Location {
        const base = self.data orelse return &.{};
        return @as([*]Location, @ptrCast(base))[0..self.len];
    }

    pub fn keys(self: Chunk) []u16 {
        const base = self.data orelse return &.{};
        return @as([*]u16, @ptrCast(@alignCast(base + @as(usize, self.capacity) * @sizeOf(Location))))[0..self.len];
    }

    fn find(self: Chunk, local: u16) ?usize {
        return std.mem.indexOfScalar(u16, self.keys(), local);
    }

    fn bytes(capacity: usize) usize {
        return capacity * (@sizeOf(Location) + @sizeOf(u16));
    }

    fn grow(self: *Chunk, allocator: std.mem.Allocator, needed: usize) !void {
        if (needed <= self.capacity) return;
        const capacity = @max(needed, @min(@as(usize, self.capacity) * 2, std.math.maxInt(u16)), 8);
        if (capacity > std.math.maxInt(u16)) return error.IndexFull;
        const data = try allocator.alignedAlloc(u8, .of(Location), bytes(capacity));
        var next: Chunk = .{ .data = data.ptr, .len = self.len, .capacity = @intCast(capacity) };
        @memcpy(next.locations(), self.locations());
        @memcpy(next.keys(), self.keys());
        self.free(allocator);
        self.* = next;
    }

    fn free(self: *Chunk, allocator: std.mem.Allocator) void {
        const base = self.data orelse return;
        allocator.free(base[0..bytes(self.capacity)]);
        self.* = .{};
    }

    fn put(self: *Chunk, local: u16, location: Location) ?Location {
        if (self.find(local)) |i| {
            const old = self.locations()[i];
            self.locations()[i] = location;
            return old;
        }
        std.debug.assert(self.len < self.capacity);
        const keys_ = self.keys();
        var at = keys_.len;
        while (at > 0 and keys_[at - 1] > local) at -= 1;
        self.len += 1;
        const grown_keys = self.keys();
        const grown_locations = self.locations();
        std.mem.copyBackwards(u16, grown_keys[at + 1 ..], grown_keys[at .. grown_keys.len - 1]);
        std.mem.copyBackwards(Location, grown_locations[at + 1 ..], grown_locations[at .. grown_locations.len - 1]);
        grown_keys[at] = local;
        grown_locations[at] = location;
        return null;
    }

    fn remove(self: *Chunk, local: u16) ?Location {
        const i = self.find(local) orelse return null;
        const old = self.locations()[i];
        const keys_ = self.keys();
        const locations_ = self.locations();
        std.mem.copyForwards(u16, keys_[i..], keys_[i + 1 ..]);
        std.mem.copyForwards(Location, locations_[i..], locations_[i + 1 ..]);
        self.len -= 1;
        return old;
    }
};

pub const Change = struct {
    slot: u10,
    local: u16,
    location: ?Location,

    fn lessThan(_: void, a: Change, b: Change) bool {
        if (a.slot != b.slot) return a.slot < b.slot;
        return a.local < b.local;
    }
};

/// Valid until the next prepare.
pub const Prepared = struct {
    changes: []const Change,
    order: scan.Order,
    bytes: u64,
};

pub const Entry = struct {
    local: u16,
    location: Location,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    region: Region,
    generation: u64,
    max_keys: u32,
    chunks: *[1024]Chunk,
    count: u32 = 0,
    order: scan.Order = .{},
    stats: ?*Stats = null,
    fingerprints: bool = false,
    total_bytes: u64 = 0,
    live_bytes: u64 = 0,
    changes: std.ArrayListUnmanaged(Change) = .empty,

    pub fn init(allocator: std.mem.Allocator, region: Region, generation: u64, max_keys: u32) !Index {
        try region.validate();
        const chunks = try allocator.create([1024]Chunk);
        chunks.* = @splat(.{});
        return .{ .allocator = allocator, .region = region, .generation = generation, .max_keys = max_keys, .chunks = chunks };
    }

    pub fn deinit(self: *Index) void {
        for (self.chunks) |*c| c.free(self.allocator);
        self.allocator.destroy(self.chunks);
        self.changes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn lastBatchId(self: *const Index) u64 {
        return self.order.last_batch_id;
    }

    pub fn get(self: *const Index, key: Key) !?Location {
        if (!key.region().eql(self.region)) return error.RegionMismatch;
        try key.validate();
        return self.lookup(key.slot(), key.local());
    }

    pub fn lookup(self: *const Index, slot: u10, local: u16) ?Location {
        const c = self.chunks[slot];
        const i = c.find(local) orelse return null;
        return c.locations()[i];
    }

    /// The count returned may exceed `out.len`.
    pub fn chunkEntries(self: *const Index, slot: u10, out: []Entry) usize {
        const c = self.chunks[slot];
        for (c.keys()[0..@min(c.len, out.len)], c.locations()[0..@min(c.len, out.len)], out[0..@min(c.len, out.len)]) |local, location, *entry| {
            entry.* = .{ .local = local, .location = location };
        }
        return c.len;
    }

    pub fn appendKeys(self: *const Index, allocator: std.mem.Allocator, filter: KeyFilter, list: *std.ArrayListUnmanaged(Key)) !void {
        for (self.chunks, 0..) |c, slot| {
            for (c.keys()) |local| {
                const key = Key.fromLocal(self.region, @intCast(slot), local);
                if (filter.matches(key)) try list.append(allocator, key);
            }
        }
    }

    pub fn each(self: *const Index, context: anytype, comptime visit: anytype) !void {
        for (self.chunks, 0..) |c, slot| {
            for (c.keys(), c.locations()) |local, location| try visit(context, @as(u10, @intCast(slot)), local, location);
        }
    }

    /// Nothing is visible until `publish`.
    pub fn prepare(self: *Index, batches: []const scan.Batch, segment: usize) !Prepared {
        if (segment >= max_segments) return error.InvalidSegmentId;
        var order = self.order;
        var bytes: u64 = 0;
        self.changes.clearRetainingCapacity();
        for (batches) |batch| {
            if (batch.end() > max_segment_size) return error.SegmentFull;
            try order.accept(batch.header);
            try frame.each(batch.body(), Visitor{ .index = self, .batch = batch, .segment = @intCast(segment) }, Visitor.visit);
            bytes += batch.bytes.len;
        }
        return self.finish(order, bytes);
    }

    const Visitor = struct {
        index: *Index,
        batch: scan.Batch,
        segment: u8,

        fn visit(self: Visitor, offset: usize, header: record.Header, value: []const u8) !void {
            const index = self.index;
            try index.changes.append(index.allocator, .{
                .slot = header.slot,
                .local = header.local,
                .location = if (header.delete) null else .{
                    .batch_id = self.batch.header.batch_id,
                    .offset = @intCast(self.batch.offset + offset),
                    .stored_len = header.stored_len,
                    .raw_len = header.raw_len,
                    .fingerprint = if (index.fingerprints) fingerprint(header.compression, value) else 0,
                    .segment = self.segment,
                    .compression = header.compression,
                },
            });
        }
    };

    fn finish(self: *Index, order: scan.Order, bytes: u64) !Prepared {
        const changes = latest(self.changes.items);
        var additions: u32 = 0;
        var removals: u32 = 0;
        for (changes) |change| {
            const exists = self.chunks[change.slot].find(change.local) != null;
            if (change.location != null and !exists) additions += 1;
            if (change.location == null and exists) removals += 1;
        }
        if (@as(u64, self.count) - removals + additions > self.max_keys) return error.IndexFull;

        var i: usize = 0;
        while (i < changes.len) {
            const slot = changes[i].slot;
            var added: usize = 0;
            while (i < changes.len and changes[i].slot == slot) : (i += 1) {
                if (changes[i].location != null and self.chunks[slot].find(changes[i].local) == null) added += 1;
            }
            try self.chunks[slot].grow(self.allocator, self.chunks[slot].len + added);
        }
        return .{ .changes = changes, .order = order, .bytes = bytes };
    }

    pub fn publish(self: *Index, prepared: Prepared) void {
        for (prepared.changes, 0..) |change, i| {
            const c = &self.chunks[change.slot];
            if (change.location) |location| {
                if (c.put(change.local, location)) |old| self.live_bytes -= old.recordLen() else self.count += 1;
                self.live_bytes += location.recordLen();
            } else if (c.remove(change.local)) |old| {
                self.live_bytes -= old.recordLen();
                self.count -= 1;
            }
            // Later changes in this chunk still need the reserved storage.
            if (c.len == 0 and (i + 1 == prepared.changes.len or prepared.changes[i + 1].slot != change.slot)) c.free(self.allocator);
        }
        self.total_bytes += prepared.bytes;
        self.order = prepared.order;
    }

    pub fn apply(self: *Index, batch: scan.Batch, segment: usize) !void {
        self.publish(try self.prepare(&.{batch}, segment));
    }

    /// Keys must be strictly increasing.
    pub fn loadChunk(self: *Index, slot: u10, keys: []const u16, locations: []const Location) !void {
        if (keys.len == 0) return;
        const c = &self.chunks[slot];
        if (c.len != 0 or keys.len > std.math.maxInt(u16)) return error.IndexMismatch;
        if (@as(u64, self.count) + keys.len > self.max_keys) return error.IndexFull;
        for (keys[1..], keys[0 .. keys.len - 1]) |next, previous| if (next <= previous) return error.IndexMismatch;
        try c.grow(self.allocator, keys.len);
        c.len = @intCast(keys.len);
        @memcpy(c.keys(), keys);
        @memcpy(c.locations(), locations);
        self.count += @intCast(keys.len);
        for (locations) |location| self.live_bytes += location.recordLen();
    }

    pub fn restore(self: *Index, slot: u10, local: u16, location: Location) !void {
        if (self.count == self.max_keys) return error.IndexFull;
        const c = &self.chunks[slot];
        if (c.find(local) != null) return error.IndexMismatch;
        try c.grow(self.allocator, @as(usize, c.len) + 1);
        _ = c.put(local, location);
        self.count += 1;
        self.live_bytes += location.recordLen();
    }

    pub fn memory(self: *const Index) usize {
        var total: usize = @sizeOf([1024]Chunk);
        for (self.chunks) |c| total += Chunk.bytes(c.capacity);
        return total;
    }
};

// The sort is stable, so the last change per key wins.
fn latest(changes: []Change) []Change {
    if (changes.len < 2) return changes;
    if (changes.len <= 32) std.sort.insertion(Change, changes, {}, Change.lessThan) else std.mem.sort(Change, changes, {}, Change.lessThan);
    var kept: usize = 0;
    for (changes, 0..) |change, i| {
        if (i + 1 < changes.len and changes[i + 1].slot == change.slot and changes[i + 1].local == change.local) continue;
        changes[kept] = change;
        kept += 1;
    }
    return changes[0..kept];
}

test "chunk lists stay sorted through inserts, overwrites and removals" {
    var index = try Index.init(std.testing.allocator, .{ .dimension = 0, .x = 0, .z = 0 }, 1, 1000);
    defer index.deinit();
    const location: Location = .{ .batch_id = 1, .offset = 48, .stored_len = 1, .raw_len = 1, .fingerprint = 0, .segment = 0, .compression = .none };
    var order = [_]u16{ 30, 10, 20, 5, 40, 25, 1, 2, 3, 4, 6 };
    for (order) |local| try index.restore(3, local, location);
    std.mem.sort(u16, &order, {}, std.sort.asc(u16));
    try std.testing.expectEqualSlices(u16, &order, index.chunks[3].keys());
    _ = index.chunks[3].remove(20);
    try std.testing.expectEqual(@as(?Location, null), index.lookup(3, 20));
    try std.testing.expect(index.lookup(3, 25) != null);
}
