const std = @import("std");
const db = @import("zigritedb");

pub const region: db.Region = .{ .dimension = 0, .x = 0, .z = 0 };
pub const segment_name = "0000000000000001-0000000000000001.segment";

pub fn key(x: i32) db.Key {
    return .{ .dimension = 0, .chunk_x = x, .chunk_z = 0, .component = .version };
}

/// A put, or a delete when `value` is null.
pub fn put(x: i32, value: ?[]const u8) db.Entry {
    return .{ .key = key(x), .value = value };
}

pub fn batch(id: u64, entries: []const db.Entry) db.WriteBatch {
    return .{ .id = id, .entries = entries };
}

/// Segment size that holds exactly the given batches.
pub fn segmentFor(batches: []const db.WriteBatch) !u64 {
    var size: u64 = db.segment.encoded_len;
    for (batches) |b| size += try b.validate();
    return size;
}

pub fn openFile(dir: std.Io.Dir, name: []const u8) !db.storage.File {
    return .{ .handle = try dir.openFile(std.testing.io, name, .{ .mode = .read_write }), .io = std.testing.io };
}

pub fn segmentLength(dir: std.Io.Dir) !u64 {
    return (try dir.statFile(std.testing.io, segment_name, .{})).size;
}

/// Turns on test fault injection for the rest of the scope.
pub fn inject(faults: *db.storage.Faults) void {
    db.storage.faults = faults;
}

pub fn clearFaults() void {
    db.storage.faults = null;
}
