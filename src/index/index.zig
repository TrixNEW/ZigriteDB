const std = @import("std");

const Key = @import("../format/key.zig").Key;
const Region = @import("../format/key.zig").Region;
const entry = @import("../format/entry.zig");
const manifest = @import("../format/manifest.zig");
const segment = @import("../format/segment.zig");
const commit = @import("../batch/commit.zig");
const recovery = @import("../recovery/scan.zig");
const file_scan = @import("../recovery/file_scan.zig");

const EncodedKey = [Key.encoded_len]u8;
const Map = std.AutoHashMapUnmanaged(EncodedKey, Location);
const Pending = std.AutoHashMapUnmanaged(EncodedKey, ?Location);

pub const Location = struct {
    segment_id: u64,
    offset: u64,
    batch_id: u64,
    stored_len: u32,
    raw_len: u32,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    region: Region,
    generation: u64,
    max_keys: u32,
    entries: Map = .empty,
    last_batch_id: u64 = 0,
    active_offset: usize = segment.encoded_len,
    has_tail: bool = false,

    pub fn deinit(self: *Index) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Index) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Index, key: Key) !?Location {
        return self.entries.get(try key.encode());
    }

    /// The returned value uses scratch.
    pub fn read(self: *const Index, key: Key, device: anytype, scratch: []u8) !?[]const u8 {
        const location = (try self.get(key)) orelse return null;
        const len = std.math.add(usize, entry.overhead, location.stored_len) catch return error.InvalidLength;

        if (scratch.len < len) return error.BufferTooSmall;

        var header_bytes: [segment.encoded_len]u8 = undefined;
        try device.readExact(&header_bytes, 0);

        const header = try segment.Header.decode(&header_bytes);
        try header.checkIdentity(.{
            .segment_id = location.segment_id,
            .generation = self.generation,
            .region = self.region,
        });

        try device.readExact(scratch[0..len], location.offset);

        const decoded = try entry.decode(scratch[0..len]);
        const same_record =
            decoded.entry.header.kind == .put and
            decoded.entry.header.batch_id == location.batch_id and
            decoded.entry.header.stored_len == location.stored_len and
            decoded.entry.header.raw_len == location.raw_len and
            std.meta.eql(decoded.entry.key, key);

        if (!same_record) return error.IndexMismatch;

        return decoded.entry.value;
    }

    fn apply(self: *Index, batch: recovery.Batch, segment_id: u64) !void {
        var pending: Pending = .empty;
        defer pending.deinit(self.allocator);

        const start = batch.end_offset - commit.commit_len - batch.records.len;
        var offset: usize = 0;

        while (offset < batch.records.len) {
            const decoded = try entry.decode(batch.records[offset..]);
            const item = decoded.entry;
            const key = try item.key.encode();
            const location: ?Location = if (item.header.kind == .delete) null else .{
                .segment_id = segment_id,
                .offset = try std.math.add(u64, start, offset),
                .batch_id = batch.id,
                .stored_len = item.header.stored_len,
                .raw_len = item.header.raw_len,
            };

            try pending.put(self.allocator, key, location);
            offset += decoded.consumed;
        }

        var additions: u32 = 0;
        var removals: u32 = 0;
        var changes = pending.iterator();

        while (changes.next()) |change| {
            const exists = self.entries.contains(change.key_ptr.*);

            if (change.value_ptr.* != null and !exists) additions += 1;
            if (change.value_ptr.* == null and exists) removals += 1;
        }

        const new_count = @as(u64, self.entries.count()) - removals + additions;
        if (new_count > self.max_keys) return error.IndexFull;

        // Reserve before changing any entries.
        try self.entries.ensureUnusedCapacity(self.allocator, additions);
        changes = pending.iterator();

        while (changes.next()) |change| {
            if (change.value_ptr.*) |location| {
                self.entries.putAssumeCapacity(change.key_ptr.*, location);
            } else {
                _ = self.entries.remove(change.key_ptr.*);
            }
        }

        self.last_batch_id = batch.id;
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
            try index.apply(batch, id);
        }

        if (active) {
            index.active_offset = scanner.offset;
            index.has_tail = scanner.has_tail;
        }

        previous_segment = id;
    }

    return index;
}
