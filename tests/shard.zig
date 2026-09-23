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

test "getMany resolves multiple keys in one region with one pin" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "aaa")} });
    _ = try shard.write(.{ .entries = &.{item(2, 1, "bb")} });
    _ = try shard.write(.{ .entries = &.{item(3, 2, "c")} });

    var out0: [16]u8 = undefined;
    var out1: [16]u8 = undefined;
    var out2: [16]u8 = undefined;
    const requests = [_]Shard.ReadRequest{
        .{ .key = item(1, 0, "").key, .output = &out0 },
        .{ .key = item(1, 1, "").key, .output = &out1 },
        .{ .key = item(1, 2, "").key, .output = &out2 },
    };
    var results: [3]Shard.ReadResult = undefined;
    try shard.getMany(&requests, &results);

    try testing.expectEqual(Shard.ReadStatus.ok, results[0].status);
    try testing.expectEqualStrings("aaa", out0[0..results[0].value.len]);
    try testing.expectEqual(Shard.ReadStatus.ok, results[1].status);
    try testing.expectEqualStrings("bb", out1[0..results[1].value.len]);
    try testing.expectEqual(Shard.ReadStatus.ok, results[2].status);
    try testing.expectEqualStrings("c", out2[0..results[2].value.len]);
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);
}

test "getMany reports independent status per key" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "hello")} });

    var big: [16]u8 = undefined;
    var small: [2]u8 = undefined;
    var miss_out: [16]u8 = undefined;
    const requests = [_]Shard.ReadRequest{
        .{ .key = item(1, 0, "").key, .output = &big },
        .{ .key = item(1, 0, "").key, .output = &small },
        .{ .key = item(1, 5, "").key, .output = &miss_out },
    };
    var results: [3]Shard.ReadResult = undefined;
    try shard.getMany(&requests, &results);

    try testing.expectEqual(Shard.ReadStatus.ok, results[0].status);
    try testing.expectEqualStrings("hello", big[0..results[0].value.len]);
    try testing.expectEqual(Shard.ReadStatus.buffer_too_small, results[1].status);
    try testing.expectEqual(@as(usize, 5), results[1].required);
    try testing.expectEqual(Shard.ReadStatus.not_found, results[2].status);
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);
}

test "getMany rejects a batch over the key limit" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();

    var requests: [Shard.max_batch_keys + 1]Shard.ReadRequest = undefined;
    var results: [Shard.max_batch_keys + 1]Shard.ReadResult = undefined;
    var out: [1]u8 = undefined;
    for (&requests) |*r| r.* = .{ .key = item(1, 0, "").key, .output = &out };
    try testing.expectError(error.TooManyKeys, shard.getMany(&requests, &results));
}

fn concurrentGetMany(shard: *Shard, requests: []const Shard.ReadRequest, results: []Shard.ReadResult, err: *?anyerror) void {
    shard.getMany(requests, results) catch |e| {
        err.* = e;
        return;
    };
}

test "getMany runs alongside a plain get on the same shard" {
    var device: Device = .{};
    var shard = try Shard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "shared")} });
    _ = try shard.write(.{ .entries = &.{item(2, 1, "other")} });

    var many_out: [2][16]u8 = undefined;
    const requests = [_]Shard.ReadRequest{
        .{ .key = item(1, 0, "").key, .output = &many_out[0] },
        .{ .key = item(1, 1, "").key, .output = &many_out[1] },
    };
    var many_results: [2]Shard.ReadResult = undefined;
    var many_err: ?anyerror = null;

    var single_result: ReadResult = .{};
    var single_out: [16]u8 = undefined;

    const many_thread = try std.Thread.spawn(.{}, concurrentGetMany, .{ &shard, &requests, &many_results, &many_err });
    concurrentRead(&shard, item(1, 0, "").key, &single_out, &single_result);
    many_thread.join();

    try testing.expectEqual(null, many_err);
    try testing.expectEqual(Shard.ReadStatus.ok, many_results[0].status);
    try testing.expectEqual(Shard.ReadStatus.ok, many_results[1].status);
    try testing.expectEqual(null, single_result.err);
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);
}

/// Pauses the first segment-header read so the test can mutate the shard mid-read.
const Gated = struct {
    inner: Device = .{},
    armed: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    pub fn length(self: *Gated) !u64 {
        return self.inner.length();
    }

    pub fn readExact(self: *Gated, output: []u8, offset: u64) !void {
        if (offset == 0 and self.armed.swap(false, .acq_rel)) {
            self.paused.store(true, .release);
            while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        }
        return self.inner.readExact(output, offset);
    }

    pub fn writeAll(self: *Gated, bytes: []const u8, offset: u64) !void {
        return self.inner.writeAll(bytes, offset);
    }

    pub fn sync(self: *Gated) !void {
        return self.inner.sync();
    }

    fn waitPaused(self: *Gated) void {
        while (!self.paused.load(.acquire)) std.Thread.yield() catch {};
    }
};
const GatedShard = db.shard.Shard(*Gated);

fn gatedGet(shard: *GatedShard, key: db.Key, buffer: []u8, result: *ReadResult) void {
    if (shard.get(key, buffer)) |value| {
        result.len = if (value) |v| v.len else null;
    } else |err| {
        result.err = err;
    }
}

fn gatedGetMany(shard: *GatedShard, requests: []const GatedShard.ReadRequest, results: []GatedShard.ReadResult, err: *?anyerror) void {
    shard.getMany(requests, results) catch |e| {
        err.* = e;
    };
}

/// Rewrites a key, grows the index, then deletes it.
fn churn(shard: *GatedShard, first_id: u64) !void {
    _ = try shard.write(.{ .entries = &.{item(first_id, 0, "a much longer replacement value")} });
    for (0..2) |round| {
        var entries: [12]db.entry.Entry = undefined;
        for (&entries, 0..) |*value, i| value.* = item(first_id + 1 + round, @intCast(1 + round * 12 + i), "grow");
        _ = try shard.write(.{ .entries = &entries });
    }
    _ = try shard.write(.{ .entries = &.{item(first_id + 3, 0, null)} });
}

test "a pinned get reads its captured location while writers overwrite, rehash and delete" {
    var device: Gated = .{};
    var shard = try GatedShard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });

    device.armed.store(true, .release);
    var output: [3]u8 = undefined;
    var result: ReadResult = .{};
    const reader = try std.Thread.spawn(.{}, gatedGet, .{ &shard, item(1, 0, "").key, &output, &result });
    device.waitPaused();
    try churn(&shard, 2);
    device.released.store(true, .release);
    reader.join();

    try testing.expectEqual(null, result.err);
    try testing.expectEqualStrings("old", output[0..result.len.?]);
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);
    var fresh: [3]u8 = undefined;
    try testing.expectEqual(null, try shard.get(item(1, 0, "").key, &fresh));
}

test "a pinned getMany reads its captured locations while writers overwrite, rehash and delete" {
    var device: Gated = .{};
    var shard = try GatedShard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{ item(1, 0, "old"), item(1, 30, "kept") } });

    device.armed.store(true, .release);
    var out0: [3]u8 = undefined;
    var out1: [4]u8 = undefined;
    const requests = [_]GatedShard.ReadRequest{
        .{ .key = item(1, 0, "").key, .output = &out0 },
        .{ .key = item(1, 30, "").key, .output = &out1 },
    };
    var results: [2]GatedShard.ReadResult = undefined;
    var err: ?anyerror = null;
    const reader = try std.Thread.spawn(.{}, gatedGetMany, .{ &shard, &requests, &results, &err });
    device.waitPaused();
    try churn(&shard, 2);
    device.released.store(true, .release);
    reader.join();

    try testing.expectEqual(null, err);
    try testing.expectEqual(GatedShard.ReadStatus.ok, results[0].status);
    try testing.expectEqualStrings("old", results[0].value);
    try testing.expectEqual(GatedShard.ReadStatus.ok, results[1].status);
    try testing.expectEqualStrings("kept", results[1].value);
    try testing.expectEqual(@as(usize, 0), shard.generation.readers);
}

const NullPublisher = struct {
    pub fn publish(_: NullPublisher, _: []const u8) !void {}
};

test "a pinned get survives segment rotation and a newer write to the new segment" {
    var device: Gated = .{};
    var next: Gated = .{};
    var shard = try GatedShard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });

    device.armed.store(true, .release);
    var output: [16]u8 = undefined;
    var result: ReadResult = .{};
    const reader = try std.Thread.spawn(.{}, gatedGet, .{ &shard, item(1, 0, "").key, &output, &result });
    device.waitPaused();
    try shard.rotate(&next, 2, NullPublisher{});
    _ = try shard.write(.{ .entries = &.{item(2, 0, "rotated")} });
    device.released.store(true, .release);
    reader.join();

    try testing.expectEqual(null, result.err);
    try testing.expectEqualStrings("old", output[0..result.len.?]);
    var fresh: [16]u8 = undefined;
    try testing.expectEqualStrings("rotated", (try shard.get(item(1, 0, "").key, &fresh)).?);
}

fn gatedClose(shard: *GatedShard, done: *std.atomic.Value(bool), result: *?anyerror) void {
    shard.close() catch |err| {
        result.* = err;
    };
    done.store(true, .release);
}

test "close waits for a pinned reader to finish its physical read" {
    var device: Gated = .{};
    var shard = try GatedShard.create(testing.allocator, testing.io, &device, header, options);
    defer shard.deinit();
    _ = try shard.write(.{ .entries = &.{item(1, 0, "old")} });

    device.armed.store(true, .release);
    var output: [16]u8 = undefined;
    var result: ReadResult = .{};
    const reader = try std.Thread.spawn(.{}, gatedGet, .{ &shard, item(1, 0, "").key, &output, &result });
    device.waitPaused();

    var closed: std.atomic.Value(bool) = .init(false);
    var close_result: ?anyerror = null;
    const closer = try std.Thread.spawn(.{}, gatedClose, .{ &shard, &closed, &close_result });
    // Close waits for the pinned read to finish.
    var probe: [16]u8 = undefined;
    while (true) {
        _ = shard.get(item(1, 0, "").key, &probe) catch |err| {
            try testing.expectEqual(error.Closed, err);
            break;
        };
        std.Thread.yield() catch {};
    }
    try testing.expect(!closed.load(.acquire));

    device.released.store(true, .release);
    reader.join();
    closer.join();
    try testing.expectEqual(null, result.err);
    try testing.expectEqualStrings("old", output[0..result.len.?]);
    try testing.expectEqual(null, close_result);
}
