const std = @import("std");
const db = @import("zigitedb");
const testing = std.testing;

const header: db.segment.Header = .{
    .segment_id = 1,
    .generation = 1,
    .region = .{ .dimension = 0, .x = 0, .z = 0 },
};

fn item(id: u64, kind: db.record.Kind) db.entry.Entry {
    return .{
        .header = .{ .kind = kind, .batch_id = id },
        .key = .{ .dimension = 0, .chunk_x = 1, .chunk_z = 2, .component = .metadata },
        .value = "",
    };
}

fn append(id: u64, output: []u8) !usize {
    const entries = [_]db.entry.Entry{ item(id, .put), item(id, .delete) };
    return (try (db.WriteBatch{ .entries = &entries }).encode(output)).len;
}

test "read committed batches in order" {
    var bytes: [512]u8 = undefined;
    @memcpy(bytes[0..48], &(try header.encode()));
    const first_end = 48 + try append(1, bytes[48..]);
    const end = first_end + try append(2, bytes[first_end..]);
    var scan = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, 0);
    const first = (try scan.next()).?;
    try testing.expectEqual(@as(u64, 1), first.id);
    const put = try db.entry.decode(first.records);
    const deletion = try db.entry.decode(first.records[put.consumed..]);
    try testing.expectEqual(db.record.Kind.delete, deletion.entry.header.kind);
    try testing.expectEqual(@as(u64, 2), (try scan.next()).?.id);
    try testing.expectEqual(end, scan.offset);
    try testing.expectEqual(null, try scan.next());
}

test "a cut batch is never returned" {
    var bytes: [512]u8 = undefined;
    @memcpy(bytes[0..48], &(try header.encode()));
    const first_end = 48 + try append(1, bytes[48..]);
    const end = first_end + try append(2, bytes[first_end..]);
    for (first_end + 1..end) |cut| {
        var active = try db.recovery.Scanner.init(bytes[0..cut], header, .active, 0);
        _ = (try active.next()).?;
        try testing.expectEqual(null, try active.next());
        try testing.expect(active.has_tail);
        try testing.expectEqual(first_end, active.offset);
        try testing.expectEqual(null, try active.next());

        var sealed = try db.recovery.Scanner.init(bytes[0..cut], header, .sealed, 0);
        _ = (try sealed.next()).?;
        try testing.expectError(error.IncompleteBatch, sealed.next());
    }
}

test "corruption is not an incomplete tail" {
    var bytes: [256]u8 = undefined;
    @memcpy(bytes[0..48], &(try header.encode()));
    const end = 48 + try append(1, bytes[48..]);
    bytes[48 + db.record.encoded_len] ^= 1;
    var scan = try db.recovery.Scanner.init(bytes[0..end], header, .active, 0);
    try testing.expectError(error.ChecksumMismatch, scan.next());
    try testing.expectEqual(@as(usize, 48), scan.offset);
    try testing.expect(!scan.has_tail);
}

test "batch IDs must increase across segments" {
    var bytes: [256]u8 = undefined;
    @memcpy(bytes[0..48], &(try header.encode()));
    const end = 48 + try append(2, bytes[48..]);
    for ([_]u64{ 2, 3 }) |previous| {
        var scan = try db.recovery.Scanner.init(bytes[0..end], header, .sealed, previous);
        try testing.expectError(error.BatchOrder, scan.next());
    }
}

test "records must belong to the segment region" {
    var bytes: [256]u8 = undefined;
    @memcpy(bytes[0..48], &(try header.encode()));
    var wrong = item(1, .put);
    wrong.key.chunk_x = 32;
    const encoded = try (db.WriteBatch{ .entries = &.{wrong} }).encode(bytes[48..]);
    var scan = try db.recovery.Scanner.init(bytes[0 .. 48 + encoded.len], header, .sealed, 0);
    try testing.expectError(error.RegionMismatch, scan.next());
}

test "invalid batch leaves output unchanged" {
    var bytes = [_]u8{0xaa} ** 256;
    const before = bytes;
    const mixed = [_]db.entry.Entry{ item(1, .put), item(2, .delete) };
    try testing.expectError(error.BatchIdMismatch, (db.WriteBatch{ .entries = &mixed }).encode(&bytes));
    const valid = [_]db.entry.Entry{item(1, .put)};
    try testing.expectError(error.BufferTooSmall, (db.WriteBatch{ .entries = &valid }).encode(bytes[0..8]));
    try testing.expectEqualSlices(u8, &before, &bytes);
}

test "a wrong commit does not expose the batch" {
    var bytes: [256]u8 = undefined;
    @memcpy(bytes[0..48], &(try header.encode()));
    const end = 48 + try append(1, bytes[48..]);
    const marker = bytes[end - db.batch.commit_len .. end];
    marker[44] ^= 1;
    std.mem.writeInt(u32, marker[76..80], std.hash.crc.Crc32Iscsi.hash(marker[0..76]), .little);
    var scan = try db.recovery.Scanner.init(bytes[0..end], header, .active, 0);
    try testing.expectError(error.BatchMismatch, scan.next());
    try testing.expectEqual(@as(usize, 48), scan.offset);
    try testing.expectEqual(@as(u64, 0), scan.last_batch_id);
}

test "empty segments and wrong segment identities" {
    const bytes = try header.encode();
    var scan = try db.recovery.Scanner.init(&bytes, header, .sealed, 0);
    try testing.expectEqual(null, try scan.next());
    try testing.expect(!scan.has_tail);

    var wrong = header;
    wrong.segment_id = 2;
    try testing.expectError(error.IdentityMismatch, db.recovery.Scanner.init(&bytes, wrong, .sealed, 0));
}
