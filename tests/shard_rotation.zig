const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const support = @import("support/shard.zig");
const Device = support.Device;
const Shard = db.shard.Shard(*Device);
const item = support.item;
const header = support.header;
const options = support.options;

const Stage = enum { write, sync, replace, directory };

const Backend = struct {
    old: *Device,
    new: *Device,
    fail_at: ?Stage = null,
    temporary: [128]u8 = undefined,
    visible: [128]u8 = undefined,
    temp_len: usize = 0,
    visible_len: usize = 0,
    calls: usize = 0,

    fn init(old: *Device, new: *Device) !Backend {
        var backend: Backend = .{ .old = old, .new = new };
        const bytes = try (db.manifest.Manifest{
            .generation = 1,
            .region = header.region,
            .segments = &.{1},
        }).encode(&backend.visible);
        backend.visible_len = bytes.len;
        return backend;
    }

    fn step(self: *Backend, stage: Stage) !void {
        try testing.expectEqual(@intFromEnum(stage), self.calls);
        self.calls += 1;
        if (self.fail_at == stage) return error.InputOutput;
    }

    pub fn writeTemporary(self: *Backend, bytes: []const u8) !void {
        try testing.expectEqual(self.old.used, self.old.synced_len);
        try testing.expectEqual(self.new.used, self.new.synced_len);
        try self.step(.write);
        @memcpy(self.temporary[0..bytes.len], bytes);
        self.temp_len = bytes.len;
    }

    pub fn syncTemporary(self: *Backend) !void {
        try self.step(.sync);
    }

    pub fn replaceManifest(self: *Backend) !void {
        try self.step(.replace);
        @memcpy(self.visible[0..self.temp_len], self.temporary[0..self.temp_len]);
        self.visible_len = self.temp_len;
    }

    pub fn syncDirectory(self: *Backend) !void {
        try self.step(.directory);
    }
};

test "rotation keeps old records readable after reopen" {
    var first: Device = .{};
    var second: Device = .{};
    var small = options;
    small.durability = .buffered;
    small.max_segment_size = 48 + try (db.WriteBatch{ .entries = &.{item(1, 0, "old")} }).size();
    var shard = try Shard.create(testing.allocator, testing.io, &first, header, small);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });
    var backend = try Backend.init(&first, &second);
    var publisher: db.publication.Publisher(*Backend) = .{ .backend = &backend };

    try testing.expectError(error.SegmentFull, shard.write(.{ .entries = &.{item(2, 1, "new")} }));
    try shard.rotate(&second, 2, &publisher);
    _ = try shard.write(.{ .entries = &.{item(2, 1, "new")} });
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("old", (try shard.get(item(1, 0, "").key, &output)).?);
    try testing.expectEqualStrings("new", (try shard.get(item(1, 1, "").key, &output)).?);
    try shard.close();

    var ids: [2]u64 = undefined;
    const metadata = try db.manifest.decode(backend.visible[0..backend.visible_len], &ids);
    var reopened = try Shard.openSegments(testing.allocator, testing.io, &.{ &first, &second }, metadata, options);
    defer reopened.deinit();
    try testing.expectEqualStrings("old", (try reopened.get(item(1, 0, "").key, &output)).?);
    try testing.expectEqualStrings("new", (try reopened.get(item(1, 1, "").key, &output)).?);
}

test "publication failures stop writes and preserve recovery" {
    for (std.enums.values(Stage)) |stage| {
        var first: Device = .{};
        var second: Device = .{};
        var shard = try Shard.create(testing.allocator, testing.io, &first, header, options);
        defer shard.deinit();
        _ = try shard.write(.{ .entries = &.{item(1, 0, "saved")} });
        var backend = try Backend.init(&first, &second);
        backend.fail_at = stage;
        var publisher: db.publication.Publisher(*Backend) = .{ .backend = &backend };

        try testing.expectError(error.InputOutput, shard.rotate(&second, 2, &publisher));
        try testing.expectError(error.WriterFailed, shard.write(.{ .entries = &.{item(2, 0, "later")} }));
        try testing.expectEqual(@as(usize, 48), second.used);

        var ids: [2]u64 = undefined;
        const metadata = try db.manifest.decode(backend.visible[0..backend.visible_len], &ids);
        const devices = [_]*Device{ &first, &second };
        var reopened = try Shard.openSegments(testing.allocator, testing.io, devices[0..metadata.segments.len], metadata, options);
        defer reopened.deinit();
        var output: [128]u8 = undefined;
        try testing.expectEqualStrings("saved", (try reopened.get(item(1, 0, "").key, &output)).?);
    }
}

test "rotation rejects limits and reused IDs before creating files" {
    var first: Device = .{};
    var second: Device = .{};
    var limited = options;
    limited.max_segments = 1;
    var shard = try Shard.create(testing.allocator, testing.io, &first, header, limited);
    defer shard.deinit();
    var backend = try Backend.init(&first, &second);
    var publisher: db.publication.Publisher(*Backend) = .{ .backend = &backend };

    try testing.expectError(error.TooManySegments, shard.rotate(&second, 2, &publisher));
    try testing.expectEqual(@as(usize, 0), second.used);
    try testing.expectEqual(@as(usize, 0), backend.calls);
}

test "new segment sync failure never publishes a manifest" {
    var first: Device = .{};
    var second: Device = .{ .fail_sync = true };
    var shard = try Shard.create(testing.allocator, testing.io, &first, header, options);
    defer shard.deinit();
    var backend = try Backend.init(&first, &second);
    var publisher: db.publication.Publisher(*Backend) = .{ .backend = &backend };

    try testing.expectError(error.InvalidSegmentOrder, shard.rotate(&second, 1, &publisher));
    try testing.expectEqual(@as(usize, 0), second.used);
    try testing.expectError(error.InputOutput, shard.rotate(&second, 2, &publisher));
    try testing.expectEqual(@as(usize, 0), backend.calls);
    _ = try shard.write(.{ .entries = &.{item(1, 0, "still usable")} });
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var first: Device = .{};
    var second: Device = .{};
    var shard = try Shard.create(allocator, testing.io, &first, header, options);
    defer shard.deinit();
    var backend = try Backend.init(&first, &second);
    var publisher: db.publication.Publisher(*Backend) = .{ .backend = &backend };

    shard.rotate(&second, 2, &publisher) catch |err| {
        try testing.expectEqual(@as(usize, 0), second.used);
        try testing.expectEqual(@as(usize, 0), backend.calls);
        return err;
    };
}

test "rotation allocations happen before disk changes" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
}

test "old segment sync failure leaves the new device untouched" {
    var first: Device = .{};
    var second: Device = .{};
    var buffered = options;
    buffered.durability = .buffered;
    var shard = try Shard.create(testing.allocator, testing.io, &first, header, buffered);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "saved")} });
    first.fail_sync = true;
    var backend = try Backend.init(&first, &second);
    var publisher: db.publication.Publisher(*Backend) = .{ .backend = &backend };

    try testing.expectError(error.InputOutput, shard.rotate(&second, 2, &publisher));
    try testing.expectEqual(@as(usize, 0), second.used);
    try testing.expectEqual(@as(usize, 0), backend.calls);
}
