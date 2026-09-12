const std = @import("std");
const db = @import("zigitedb");
const batch = db.batch;
const testing = std.testing;

fn put(id: u64, x: i32, value: []const u8, buffer: []u8) ![]u8 {
    return (db.entry.Entry{
        .header = .{
            .kind = .put,
            .batch_id = id,
            .stored_len = @intCast(value.len),
            .raw_len = @intCast(value.len),
        },
        .key = .{ .dimension = 0, .chunk_x = x, .chunk_z = 0, .component = .metadata },
        .value = value,
    }).encode(buffer);
}

test "valid batch" {
    var buffer: [256]u8 = undefined;
    const first = try put(7, 0, "one", &buffer);
    const second = try put(7, 1, "two", buffer[first.len..]);
    const records = buffer[0 .. first.len + second.len];
    const commit = try batch.seal(records);
    try batch.verify(records, &commit);
}

test "changed batch" {
    var buffer: [256]u8 = undefined;
    var changed: [256]u8 = undefined;
    const first = try put(7, 0, "one", &buffer);
    const second = try put(7, 1, "two", buffer[first.len..]);
    const records = buffer[0 .. first.len + second.len];
    const commit = try batch.seal(records);
    try testing.expectError(error.BatchMismatch, batch.verify(first, &commit));

    @memcpy(changed[0..second.len], second);
    @memcpy(changed[second.len..records.len], first);
    try testing.expectError(error.BatchMismatch, batch.verify(changed[0..records.len], &commit));

    @memcpy(changed[0..first.len], first);
    @memcpy(changed[first.len..records.len], first);
    try testing.expectError(error.BatchMismatch, batch.verify(changed[0..records.len], &commit));

    @memcpy(changed[0..first.len], first);
    _ = try put(7, 1, "new", changed[first.len..]);
    try testing.expectError(error.BatchMismatch, batch.verify(changed[0..records.len], &commit));
}

test "damaged commit" {
    var buffer: [128]u8 = undefined;
    const records = try put(1, 0, "", &buffer);
    const commit = try batch.seal(records);
    for (0..batch.commit_len) |len| {
        try testing.expectError(error.IncompleteCommit, batch.verify(records, commit[0..len]));
    }
    for (0..batch.commit_len * 8) |bit| {
        var damaged = commit;
        damaged[bit / 8] ^= @as(u8, 1) << @as(u3, @intCast(bit % 8));
        const expected = if (bit < 32) error.InvalidMagic else if (bit < 40) error.UnsupportedVersion else error.ChecksumMismatch;
        try testing.expectError(expected, batch.verify(records, &damaged));
    }
}

test "mixed batches and regions" {
    var buffer: [256]u8 = undefined;
    const first = try put(1, 0, "", &buffer);
    var second = try put(2, 1, "", buffer[first.len..]);
    try testing.expectError(error.BatchIdMismatch, batch.seal(buffer[0 .. first.len + second.len]));
    second = try put(1, 32, "", buffer[first.len..]);
    try testing.expectError(error.RegionMismatch, batch.seal(buffer[0 .. first.len + second.len]));
    try testing.expectError(error.EmptyBatch, batch.seal(""));
    try testing.expectError(error.TruncatedRecord, batch.seal(first[0 .. first.len - 1]));
}

test "batch size limit" {
    const bytes = try testing.allocator.alloc(u8, (batch.max_records + 1) * db.entry.overhead);
    defer testing.allocator.free(bytes);
    for (0..batch.max_records + 1) |index| {
        _ = try put(1, 0, "", bytes[index * db.entry.overhead ..]);
    }
    const valid = bytes[0 .. batch.max_records * db.entry.overhead];
    const commit = try batch.seal(valid);
    try batch.verify(valid, &commit);
    try testing.expectError(error.BatchTooLarge, batch.seal(bytes));
}

test "wrong commit details" {
    var buffer: [128]u8 = undefined;
    const records = try put(1, 0, "", &buffer);
    const original = try batch.seal(records);
    for ([_]usize{ 32, 36, 44 }) |offset| {
        var commit = original;
        commit[offset] += 1;
        std.mem.writeInt(u32, commit[76..80], std.hash.crc.Crc32Iscsi.hash(commit[0..76]), .little);
        try testing.expectError(error.BatchMismatch, batch.verify(records, &commit));
    }
}
