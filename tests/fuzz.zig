const std = @import("std");
const db = @import("zigritedb");

test "bounded format and recovery fuzzing" {
    try std.testing.fuzz(@as(void, {}), check, .{ .corpus = &.{ "", "ZGSG", "ZGMF" } });
}

fn ignore(_: void, _: usize, _: db.record.Header, _: []const u8) void {}

fn check(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const length = smith.sliceWithHash(&buffer, 0);
    const bytes = buffer[0..length];
    _ = db.record.decode(bytes) catch {};
    _ = db.frame.verify(bytes, 1, {}, ignore) catch {};
    _ = db.segment.Header.decode(bytes) catch {};
    if (bytes.len >= db.checkpoint.header_len) _ = db.checkpoint.Header.read(bytes[0..db.checkpoint.header_len]) catch {};
    if (bytes.len >= db.checkpoint.entry_len + 4) _ = db.checkpoint.readEntry(bytes, true) catch {};
    var log: db.leveldb.LogReader = .{ .bytes = bytes };
    defer log.deinit(std.testing.allocator);
    while (log.next(std.testing.allocator) catch null) |_| {}
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    db.leveldb.parse(arena.allocator(), bytes);
    var inflated: std.ArrayListUnmanaged(u8) = .empty;
    db.leveldb.decompress(arena.allocator(), if (length % 2 == 0) 2 else 4, bytes, &inflated) catch {};
    var entries: db.aux.Entries = .{ .bytes = bytes };
    while (entries.next() catch null) |_| {}
    var ids: [db.manifest.max_segments]u64 = undefined;
    _ = db.manifest.decode(bytes, &ids) catch {};
    var output: [4096]u8 = undefined;
    const raw_length = smith.valueRangeAtMostWithHash(u32, 0, output.len, 1);
    _ = db.lz4.decompress(bytes, &output, raw_length) catch {};

    const header: db.segment.Header = .{ .generation = 1, .segment_id = 1, .region = .{ .dimension = 0, .x = 0, .z = 0 }, .salt = 1 };
    var segment: [4096 + db.segment.encoded_len]u8 = undefined;
    @memcpy(segment[0..db.segment.encoded_len], &(try header.encode()));
    @memcpy(segment[db.segment.encoded_len..][0..length], bytes);
    inline for (.{ .active, .sealed }) |mode| {
        var scanner = try db.recovery.Scanner.init(segment[0 .. db.segment.encoded_len + length], header, mode, .{});
        while (scanner.next() catch null) |batch| {
            // Anything the scanner accepts must also index cleanly.
            var index = try db.index.Index.init(std.testing.allocator, header.region, 1, 1 << 16);
            defer index.deinit();
            try index.apply(batch, 0);
        }
    }
}
