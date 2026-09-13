const std = @import("std");

/// Errors may leave `buffer` partially filled
pub fn readExact(device: anytype, buffer: []u8, offset: u64) !void {
    try checkRange(offset, buffer.len);

    var done: usize = 0;

    while (done < buffer.len) {
        const position = offset + @as(u64, @intCast(done));
        const count = try device.readSome(buffer[done..], position);

        if (count == 0) return error.UnexpectedEndOfFile;
        if (count > buffer.len - done) return error.InvalidTransfer;

        done += count;
    }
}

/// Errors may leave a partial write on disk
pub fn writeAll(device: anytype, bytes: []const u8, offset: u64) !void {
    try checkRange(offset, bytes.len);

    var done: usize = 0;

    while (done < bytes.len) {
        const position = offset + @as(u64, @intCast(done));
        const count = try device.writeSome(bytes[done..], position);

        if (count == 0) return error.NoProgress;
        if (count > bytes.len - done) return error.InvalidTransfer;

        done += count;
    }
}

fn checkRange(offset: u64, len: usize) error{InvalidOffset}!void {
    const length = std.math.cast(u64, len) orelse return error.InvalidOffset;
    _ = std.math.add(u64, offset, length) catch return error.InvalidOffset;
}
