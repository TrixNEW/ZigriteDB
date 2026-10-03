const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;
const support = @import("support/region.zig");
const key = support.key;
const put = support.put;
const batch = support.batch;

test "overlay reads fall through to the base, tombstones hide it and reset discards everything" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "template", .default_dir);
    const template = try tmp.dir.openDir(io, "template", .{});
    defer template.close(io);

    var base = try db.World.open(testing.allocator, io, template, .{});
    defer base.deinit();
    var big: [10000]u8 = undefined;
    @memset(&big, 'b');
    _ = try base.write(batch(1, &.{ put(0, "base0"), put(1, "base1"), put(2, "base2") }));

    var overlay = try db.OverlayWorld.open(testing.allocator, io, &base, tmp.dir, "arena", .{});
    defer overlay.deinit();
    var output: [16384]u8 = undefined;

    try overlay.write(&.{ put(0, "mine"), put(1, null), put(3, &big) });
    try overlay.write(&.{put(4, null)});

    try testing.expectEqualStrings("mine", (try overlay.get(key(0), &output)).?);
    try testing.expectEqual(null, try overlay.get(key(1), &output));
    try testing.expectEqualStrings("base2", (try overlay.get(key(2), &output)).?);
    try testing.expectEqualSlices(u8, &big, (try overlay.get(key(3), &output)).?);
    try testing.expectEqual(null, try overlay.get(key(5), &output));

    try testing.expectEqual(db.OverlayWorld.Lookup.deleted, try overlay.lookup(key(1), &output));
    try testing.expectEqual(db.OverlayWorld.Lookup.deleted, try overlay.lookup(key(4), &output));
    try testing.expectEqual(db.OverlayWorld.Lookup.absent, try overlay.lookup(key(2), &output));
    try testing.expectEqualStrings("mine", (try overlay.lookup(key(0), &output)).value);
    try testing.expectError(error.BufferTooSmall, overlay.get(key(3), output[0..10]));

    try overlay.reset();
    try testing.expectEqualStrings("base0", (try overlay.get(key(0), &output)).?);
    try testing.expectEqualStrings("base1", (try overlay.get(key(1), &output)).?);
    try testing.expectEqual(null, try overlay.get(key(3), &output));

    try overlay.write(&.{put(2, "again")});
    try testing.expectEqualStrings("again", (try overlay.get(key(2), &output)).?);
    try overlay.close();

    try testing.expectEqualStrings("base0", (try base.get(key(0), &output)).?);
    try testing.expectEqualStrings("base2", (try base.get(key(2), &output)).?);
    try base.close();
}
