const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const support = @import("support/shard.zig");
const header = support.header;
const options = support.options;
const item = support.item;
const Device = support.Device;
const Shard = db.shard.Shard(*Device);

test "writes and deletes become readable together" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    var output: [128]u8 = undefined;

    _ = try shard.write(.{ .entries = &.{ item(1, 0, "old"), item(1, 1, "gone") } });
    _ = try shard.write(.{ .entries = &.{ item(2, 0, "new"), item(2, 1, null) } });

    try testing.expectEqualStrings("new", (try shard.get(item(1, 0, "").key, &output)).?);
    try testing.expectEqual(null, try shard.get(item(1, 1, "").key, &output));
}

test "failed writes leave the old index visible" {
    for ([_]bool{ false, true }) |sync_failure| {
        var device: Device = .{};
        var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
        defer shard.deinit();
        _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });

        device.fail_sync = sync_failure;
        device.fail_write = !sync_failure;
        const expected = if (sync_failure) error.InputOutput else error.NoSpaceLeft;
        try testing.expectError(expected, shard.write(.{ .entries = &.{ item(2, 0, "new"), item(2, 1, "extra") } }));

        var output: [128]u8 = undefined;
        try testing.expectEqualStrings("old", (try shard.get(item(1, 0, "").key, &output)).?);
        try testing.expectEqual(null, try shard.get(item(1, 1, "").key, &output));
        try testing.expectError(error.WriterFailed, shard.write(.{ .entries = &.{item(3, 0, "later")} }));
    }
}

test "index limits are checked before writing" {
    var device: Device = .{};
    var limited = options;
    limited.max_keys = 1;
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, limited);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });
    const length = device.used;

    try testing.expectError(error.IndexFull, shard.write(.{ .entries = &.{item(2, 1, "extra")} }));
    try testing.expectEqual(length, device.used);
    _ = try shard.write(.{ .entries = &.{ item(2, 0, null), item(2, 1, "new") } });
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var device: Device = .{};
    var shard = try Shard.create(allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });
    const length = device.used;
    var entries: [12]db.entry.Entry = undefined;

    for (&entries, 0..) |*value, x| value.* = item(2, @intCast(x), "new");

    _ = shard.write(.{ .entries = &entries }) catch |err| {
        try testing.expectEqual(length, device.used);
        var output: [128]u8 = undefined;
        try testing.expectEqualStrings("old", (try shard.get(item(1, 0, "").key, &output)).?);
        return err;
    };
}

test "allocation failure cannot reach the disk write" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
}

fn competingWrite(shard: *Shard, result: *?anyerror) void {
    _ = shard.write(.{ .entries = &.{item(1, 0, "value")} }) catch |err| {
        result.* = err;
        return;
    };
    result.* = null;
}

test "concurrent writes cannot publish the same batch twice" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    var first_result: ?anyerror = null;
    var second_result: ?anyerror = null;

    const first = try std.Thread.spawn(.{}, competingWrite, .{ &shard, &first_result });
    {
        defer first.join();
        const second = try std.Thread.spawn(.{}, competingWrite, .{ &shard, &second_result });
        second.join();
    }

    try testing.expect((first_result == null) != (second_result == null));
    try testing.expectEqual(error.BatchOrder, first_result orelse second_result.?);
}

test "close flushes buffered writes and rejects later calls" {
    var device: Device = .{};
    var buffered = options;
    buffered.durability = .buffered;
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, buffered);
    defer shard.deinit();

    try testing.expect(!(try shard.write(.{ .entries = &.{item(1, 0, "value")} })).synced);
    try shard.close();
    try shard.close();

    var output: [128]u8 = undefined;
    try testing.expectError(error.Closed, shard.get(item(1, 0, "").key, &output));
    try testing.expectError(error.Closed, shard.flush());
    try testing.expectError(error.Closed, shard.write(.{ .entries = &.{item(2, 0, "later")} }));
}

test "close frees memory even when sync fails" {
    var device: Device = .{};
    var buffered = options;
    buffered.durability = .buffered;
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, buffered);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "value")} });
    device.fail_sync = true;

    try testing.expectError(error.InputOutput, shard.close());
    try testing.expectError(error.Closed, shard.flush());
}

test "open restores data and accepts new writes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const handle = try tmp.dir.createFile(io, "shard", .{ .read = true, .exclusive = true });
        defer handle.close(io);
        const file: db.storage.File = .{ .handle = handle, .io = io };
        var shard = try db.shard.Shard(db.storage.File).create(testing.allocator, io, file, header, options);
        defer shard.deinit();
        _ = try shard.write(.{ .entries = &.{item(1, 0, "saved")} });
        try shard.close();
    }

    const handle = try tmp.dir.openFile(io, "shard", .{ .mode = .read_write });
    defer handle.close(io);
    const file: db.storage.File = .{ .handle = handle, .io = io };
    var shard = try db.shard.Shard(db.storage.File).open(testing.allocator, io, file, header, options);
    defer shard.deinit();
    var output: [128]u8 = undefined;
    try testing.expectEqualStrings("saved", (try shard.get(item(1, 0, "").key, &output)).?);
    _ = try shard.write(.{ .entries = &.{item(2, 0, "updated")} });
    try testing.expectEqualStrings("updated", (try shard.get(item(1, 0, "").key, &output)).?);
    try shard.close();
}

test "open refuses partial data and sync errors" {
    var device: Device = .{};
    {
        var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
        defer shard.deinit();
        _ = try shard.write(.{ .entries = &.{item(1, 0, "saved")} });
        try shard.close();
    }

    device.fail_sync = true;
    try testing.expectError(error.InputOutput, Shard.open(testing.allocator, testing.io, &device, header, options));
    device.fail_sync = false;
    device.used -= 1;
    try testing.expectError(error.NeedsRecovery, Shard.open(testing.allocator, testing.io, &device, header, options));
}

test "losing unsynced writes preserves the last flushed batch" {
    for ([_]bool{ false, true }) |flush| {
        var device: Device = .{};
        var buffered = options;
        buffered.durability = .buffered;
        var shard = try Shard.create(testing.allocator, testing.io, &device, header, buffered);
        defer shard.deinit();
        _ = try shard.write(.{ .entries = &.{item(1, 0, "saved")} });
        try shard.flush();
        _ = try shard.write(.{ .entries = &.{ item(2, 0, "new"), item(2, 1, "extra") } });
        if (flush) try shard.flush();
        shard.deinit();
        device.used = device.synced_len;
        var reopened = try Shard.open(testing.allocator, testing.io, &device, header, buffered);
        defer reopened.deinit();
        var value: [128]u8 = undefined;
        try testing.expectEqualStrings(if (flush) "new" else "saved", (try reopened.get(item(1, 0, "").key, &value)).?);
        const extra = try reopened.get(item(2, 1, "").key, &value);
        if (flush) try testing.expectEqualStrings("extra", extra.?) else try testing.expectEqual(null, extra);
        try testing.expectEqual(@as(u64, if (flush) 2 else 1), reopened.generation.index.last_batch_id);
    }
}

const ReadResult = struct { len: ?usize = null, err: ?anyerror = null };

fn concurrentRead(shard: *Shard, key: db.Key, buffer: []u8, result: *ReadResult) void {
    if (shard.get(key, buffer)) |value| {
        result.len = if (value) |v| v.len else null;
    } else |err| {
        result.err = err;
    }
}

test "concurrent same-key reads all see the correct value" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "shared")} });
    const key = item(1, 0, "").key;

    var buffers: [8][128]u8 = undefined;
    var results: [8]ReadResult = undefined;
    for (&results) |*r| r.* = .{};
    var threads: [8]std.Thread = undefined;
    for (0..8) |i| threads[i] = try std.Thread.spawn(.{}, concurrentRead, .{ &shard, key, &buffers[i], &results[i] });
    for (threads) |t| t.join();

    for (0..8) |i| {
        try testing.expectEqual(null, results[i].err);
        try testing.expectEqualStrings("shared", buffers[i][0 .. results[i].len orelse 0]);
    }
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);
}

test "a corrupted read releases its pin so close does not hang" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });

    device.bytes[db.segment.encoded_len + 10] ^= 1;

    var output: [128]u8 = undefined;
    try testing.expectError(error.ChecksumMismatch, shard.get(item(1, 0, "").key, &output));
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);

    try shard.close();
}
