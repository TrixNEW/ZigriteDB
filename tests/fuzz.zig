const std = @import("std");
const db = @import("zigritedb");

test "bounded format and recovery fuzzing" {
    try std.testing.fuzz(@as(void, {}), check, .{ .corpus = &.{ "", "ZGRC", "ZGSG", "ZGMF" } });
}

fn check(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const length = smith.sliceWithHash(&buffer, 0);
    const bytes = buffer[0..length];
    _ = db.Key.decode(bytes) catch {};
    _ = db.record.Header.decode(bytes) catch {};
    _ = db.segment.Header.decode(bytes) catch {};
    _ = db.entry.decode(bytes) catch {};
    var ids: [db.manifest.max_segments]u64 = undefined;
    _ = db.manifest.decode(bytes, &ids) catch {};
    var output: [4096]u8 = undefined;
    const raw_length = smith.valueRangeAtMostWithHash(u32, 0, output.len, 1);
    _ = db.lz4.decompress(bytes, &output, raw_length) catch {};

    const header: db.segment.Header = .{
        .generation = 1,
        .segment_id = 1,
        .region = .{ .dimension = 0, .x = 0, .z = 0 },
    };
    var segment: [4096 + db.segment.encoded_len]u8 = undefined;
    @memcpy(segment[0..db.segment.encoded_len], &(try header.encode()));
    @memcpy(segment[db.segment.encoded_len..][0..length], bytes);
    inline for (.{ .active, .sealed }) |mode| {
        var scanner = try db.recovery.Scanner.init(segment[0 .. db.segment.encoded_len + length], header, mode, 0);
        while (scanner.next() catch null) |_| {}
    }
}
