const std = @import("std");

const commit = @import("../batch/commit.zig");
const lz4 = @import("../compression/lz4.zig");
const entry = @import("../format/entry.zig");
const record = @import("../format/record.zig");
const Key = @import("../format/key.zig").Key;
const KeyFilter = @import("../format/key.zig").KeyFilter;
const Region = @import("../format/key.zig").Region;
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const file_scan = @import("../recovery/file_scan.zig");
const recovery = @import("../recovery/scan.zig");
const Stats = @import("../stats.zig").Stats;
const WriteBatch = @import("../batch/write.zig").WriteBatch;

const PackedKey = packed struct(u64) {
    local_x: u5,
    local_z: u5,
    component: u3,
    subchunk_y: i32,
    reserved: u19 = 0,
};

const Map = std.AutoHashMapUnmanaged(u64, Location);

pub const Location = struct {
    offset: u64,
    batch_id: u64,
    stored_len: u32,
    raw_len: u32,
    fingerprint: u32,
    segment: u16,
};

comptime {
    std.debug.assert(@sizeOf(Location) == 32);
}

pub fn fingerprint(compression: record.Compression, stored: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(@intFromEnum(compression), stored));
}

pub const Change = struct {
    key: u64,
    location: ?Location,
};

// Valid until the next prepare().
pub const Prepared = struct {
    changes: []const Change,
    batch_id: u64,
};

// The sort is stable, so the last change per key wins.
fn latestPerKey(changes: []Change) []Change {
    if (changes.len < 2) return changes;
    std.mem.sort(Change, changes, {}, changeLessThan);
    var kept: usize = 0;
    for (changes, 0..) |change, i| {
        if (i + 1 < changes.len and changes[i + 1].key == change.key) continue;
        changes[kept] = change;
        kept += 1;
    }
    return changes[0..kept];
}

fn changeLessThan(_: void, a: Change, b: Change) bool {
    return a.key < b.key;
}

pub const Index = struct {
    allocator: std.mem.Allocator,
    region: Region,
    generation: u64,
    max_keys: u32,
    entries: Map = .empty,
    last_batch_id: u64 = 0,
    active_offset: usize = segment.encoded_len,
    has_tail: bool = false,
    stats: ?*Stats = null,
    segment_ids: []const u64 = &.{},
    changes: std.ArrayListUnmanaged(Change) = .empty,
    // Only skip_unchanged needs these.
    fingerprints: bool = true,

    pub fn deinit(self: *Index) void {
        self.entries.deinit(self.allocator);
        self.changes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Index) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Index, key: Key) !?Location {
        if (!std.meta.eql(key.region(), self.region)) return error.RegionMismatch;
        return self.entries.get(try packKey(key));
    }

    fn packKey(key: Key) !u64 {
        try key.validate();
        const packed_key: PackedKey = .{
            .local_x = @intCast(@mod(key.chunk_x, 32)),
            .local_z = @intCast(@mod(key.chunk_z, 32)),
            .component = @intCast(@intFromEnum(key.component)),
            .subchunk_y = key.subchunk_y,
        };
        return @bitCast(packed_key);
    }

    fn unpackKey(self: *const Index, value: u64) Key {
        const packed_key: PackedKey = @bitCast(value);
        return .{
            .dimension = self.region.dimension,
            .chunk_x = self.region.x * 32 + @as(i32, packed_key.local_x),
            .chunk_z = self.region.z * 32 + @as(i32, packed_key.local_z),
            .component = @enumFromInt(packed_key.component),
            .subchunk_y = packed_key.subchunk_y,
        };
    }

    pub fn appendKeys(self: *const Index, allocator: std.mem.Allocator, filter: KeyFilter, list: *std.ArrayListUnmanaged(Key)) !void {
        var it = self.entries.keyIterator();
        while (it.next()) |value| {
            const key = self.unpackKey(value.*);
            if (filter.matches(key)) try list.append(allocator, key);
        }
    }

    pub fn read(self: *const Index, key: Key, device: anytype, scratch: []u8) !?[]const u8 {
        const item = (try self.readRecord(key, device, scratch)) orelse return null;
        if (item.header.compression == .none) return item.value;
        const used = entry.overhead + item.value.len;
        return try lz4.decompress(item.value, scratch[used..], item.header.raw_len);
    }

    pub fn readLocationInto(self: *const Index, location: Location, key: Key, device: anytype, scratch: []u8, output: []u8) ![]const u8 {
        try self.verifySegmentHeader(device, self.segment_ids[location.segment]);
        return self.readAtInto(location, key, device, scratch, output);
    }

    pub fn readAtInto(self: *const Index, location: Location, key: Key, device: anytype, scratch: []u8, output: []u8) ![]const u8 {
        return decodeInto(try self.readRecordAt(location, key, device, scratch), output);
    }

    fn decodeInto(item: entry.Entry, output: []u8) ![]const u8 {
        if (output.len < item.header.raw_len) return error.BufferTooSmall;
        if (item.header.compression == .lz4) return try lz4.decompress(item.value, output, item.header.raw_len);
        @memcpy(output[0..item.value.len], item.value);
        return output[0..item.value.len];
    }

    pub fn verifySegmentHeader(self: *const Index, device: anytype, segment_id: u64) !void {
        var header_bytes: [segment.encoded_len]u8 = undefined;
        try device.readExact(&header_bytes, 0);

        const header = try segment.Header.decode(&header_bytes);
        try header.checkIdentity(.{
            .segment_id = segment_id,
            .generation = self.generation,
            .region = self.region,
        });

        if (self.stats) |s| {
            _ = s.disk_reads.fetchAdd(1, .monotonic);
            _ = s.bytes_read.fetchAdd(header_bytes.len, .monotonic);
        }
    }

    pub fn readRecordAt(self: *const Index, location: Location, key: Key, device: anytype, scratch: []u8) !entry.Entry {
        const len = std.math.add(usize, entry.overhead, location.stored_len) catch return error.InvalidLength;

        if (scratch.len < len) return error.BufferTooSmall;

        try device.readExact(scratch[0..len], location.offset);

        if (self.stats) |s| {
            _ = s.disk_reads.fetchAdd(1, .monotonic);
            _ = s.bytes_read.fetchAdd(@intCast(len), .monotonic);
        }

        const decoded = try entry.decode(scratch[0..len]);
        const same_record =
            decoded.entry.header.kind == .put and
            decoded.entry.header.batch_id == location.batch_id and
            decoded.entry.header.stored_len == location.stored_len and
            decoded.entry.header.raw_len == location.raw_len and
            std.meta.eql(decoded.entry.key, key);

        if (!same_record) return error.IndexMismatch;

        return decoded.entry;
    }

    fn readRecord(self: *const Index, key: Key, device: anytype, scratch: []u8) !?entry.Entry {
        const location = (try self.get(key)) orelse return null;
        try self.verifySegmentHeader(device, self.segment_ids[location.segment]);
        return try self.readRecordAt(location, key, device, scratch);
    }

    fn apply(self: *Index, batch: recovery.Batch, position: usize) !void {
        self.publish(try self.prepare(batch, position));
    }

    pub fn prepare(self: *Index, batch: recovery.Batch, position: usize) !Prepared {
        if (position >= self.segment_ids.len) return error.InvalidSegmentId;
        if (batch.id <= self.last_batch_id) return error.BatchOrder;
        if (batch.records.len == 0) return error.EmptyBatch;
        if (batch.records.len > commit.max_bytes) return error.BatchTooLarge;
        if (batch.end_offset < batch.records.len + commit.commit_len) return error.InvalidLength;

        self.changes.clearRetainingCapacity();
        const start = batch.end_offset - commit.commit_len - batch.records.len;
        var offset: usize = 0;
        var record_count: usize = 0;

        while (offset < batch.records.len) {
            const decoded = try entry.decode(batch.records[offset..]);
            const item = decoded.entry;
            if (record_count == commit.max_records) return error.BatchTooLarge;
            if (item.header.batch_id != batch.id) return error.BatchIdMismatch;

            const region = item.key.region();
            const same_region =
                region.dimension == self.region.dimension and
                region.x == self.region.x and
                region.z == self.region.z;

            if (!same_region) return error.RegionMismatch;

            record_count += 1;
            const key = try packKey(item.key);
            try self.changes.append(self.allocator, .{
                .key = key,
                .location = self.locate(item, position, try std.math.add(u64, start, offset), batch.id),
            });
            offset += decoded.consumed;
        }

        return self.finish(batch.id);
    }

    /// Batches must be encoded back to back from `start`.
    pub fn prepareBatches(self: *Index, batches: []const WriteBatch, start: u64, position: usize) !Prepared {
        if (position >= self.segment_ids.len) return error.InvalidSegmentId;

        self.changes.clearRetainingCapacity();
        var previous = self.last_batch_id;
        var offset = start;
        for (batches) |batch| {
            const id = batch.id();
            if (id <= previous) return error.BatchOrder;
            if (!std.meta.eql(batch.entries[0].key.region(), self.region)) return error.RegionMismatch;
            previous = id;

            for (batch.entries) |item| {
                try self.changes.append(self.allocator, .{
                    .key = try packKey(item.key),
                    .location = self.locate(item, position, offset, id),
                });
                offset += entry.overhead + item.header.stored_len;
            }
            offset += commit.commit_len;
        }

        return self.finish(previous);
    }

    fn locate(self: *const Index, item: entry.Entry, position: usize, offset: u64, batch_id: u64) ?Location {
        if (item.header.kind == .delete) return null;
        return .{
            .segment = @intCast(position),
            .offset = offset,
            .batch_id = batch_id,
            .stored_len = item.header.stored_len,
            .raw_len = item.header.raw_len,
            .fingerprint = if (self.fingerprints) fingerprint(item.header.compression, item.value) else 0,
        };
    }

    fn finish(self: *Index, batch_id: u64) !Prepared {
        const changes = latestPerKey(self.changes.items);
        var additions: u32 = 0;
        var removals: u32 = 0;
        for (changes) |change| {
            const exists = self.entries.contains(change.key);
            if (change.location != null and !exists) additions += 1;
            if (change.location == null and exists) removals += 1;
        }

        const new_count = @as(u64, self.entries.count()) - removals + additions;
        if (new_count > self.max_keys) return error.IndexFull;

        try self.entries.ensureTotalCapacity(self.allocator, @intCast(new_count));

        return .{ .changes = changes, .batch_id = batch_id };
    }

    pub fn publish(self: *Index, prepared: Prepared) void {
        for (prepared.changes) |change| {
            if (change.location == null) _ = self.entries.remove(change.key);
        }
        for (prepared.changes) |change| {
            if (change.location) |location| self.entries.putAssumeCapacity(change.key, location);
        }
        self.last_batch_id = prepared.batch_id;
    }
};

pub fn rebuild(
    allocator: std.mem.Allocator,
    metadata: manifest.Manifest,
    segments: []const []const u8,
    max_keys: u32,
) !Index {
    return rebuildSource(false, allocator, metadata, segments, max_keys, &.{}, 0);
}

pub fn rebuildFiles(
    allocator: std.mem.Allocator,
    metadata: manifest.Manifest,
    devices: anytype,
    max_keys: u32,
    scratch: []u8,
    max_segment_size: u64,
) !Index {
    return rebuildSource(true, allocator, metadata, devices, max_keys, scratch, max_segment_size);
}

fn rebuildSource(
    comptime files: bool,
    allocator: std.mem.Allocator,
    metadata: manifest.Manifest,
    sources: anytype,
    max_keys: u32,
    scratch: []u8,
    max_segment_size: u64,
) !Index {
    if (metadata.generation == 0) return error.InvalidGeneration;
    if (sources.len == 0 or sources.len > manifest.max_segments or
        sources.len != metadata.segments.len)
        return error.InvalidSegmentCount;

    var index: Index = .{
        .allocator = allocator,
        .region = metadata.region,
        .generation = metadata.generation,
        .max_keys = max_keys,
        .segment_ids = metadata.segments,
    };
    errdefer index.deinit();

    var previous_segment: u64 = 0;

    for (sources, metadata.segments, 0..) |source, id, position| {
        if (id == 0) return error.InvalidSegmentId;
        if (id <= previous_segment) return error.InvalidSegmentOrder;

        const active = position == sources.len - 1;
        const expected: segment.Header = .{
            .segment_id = id,
            .generation = metadata.generation,
            .region = metadata.region,
        };
        const mode: recovery.Mode = if (active) .active else .sealed;
        var scanner = if (files)
            try file_scan.Scanner(@TypeOf(source)).init(source, expected, mode, index.last_batch_id, max_segment_size)
        else
            try recovery.Scanner.init(source, expected, mode, index.last_batch_id);

        while (if (files) try scanner.next(scratch) else try scanner.next()) |batch| {
            try index.apply(batch, position);
        }

        if (active) {
            index.active_offset = scanner.offset;
            index.has_tail = scanner.has_tail;
        }

        previous_segment = id;
    }

    return index;
}
