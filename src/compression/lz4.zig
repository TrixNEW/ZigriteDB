const std = @import("std");

pub const Error = error{ BufferTooSmall, InvalidCompressedData, InvalidLength };
pub const max_size: usize = 16 * 1024 * 1024;

pub fn bound(size: usize) Error!usize {
    if (size > max_size) return error.InvalidLength;
    return size + size / 255 + 16;
}

pub const Encoder = struct {
    table: [4096]u32 = undefined,

    /// Input and output must not overlap.
    pub fn compress(self: *Encoder, input: []const u8, output: []u8) Error![]u8 {
        if (output.len < try bound(input.len)) return error.BufferTooSmall;
        @memset(&self.table, std.math.maxInt(u32));
        var anchor: usize = 0;
        var pos: usize = 0;
        var used: usize = 0;
        var misses: usize = 0;
        while (input.len >= 13 and pos <= input.len - 12) {
            const word = std.mem.readInt(u32, input[pos..][0..4], .little);
            const hash = (word *% 2654435761) >> 20;
            const previous = self.table[hash];
            self.table[hash] = @intCast(pos);
            if (previous >= pos or pos - previous > 65535 or !std.mem.eql(u8, input[previous..][0..4], input[pos..][0..4])) {
                pos += 1 + (misses >> 6);
                misses += 1;
                continue;
            }
            misses = 0;
            const limit = input.len - 5;
            var length: usize = 4;
            while (pos + length + 8 <= limit) {
                const diff = std.mem.readInt(u64, input[previous + length ..][0..8], .little) ^
                    std.mem.readInt(u64, input[pos + length ..][0..8], .little);
                if (diff != 0) {
                    length += @ctz(diff) / 8;
                    break;
                }
                length += 8;
            } else while (pos + length < limit and input[previous + length] == input[pos + length]) : (length += 1) {}
            const literals = pos - anchor;
            output[used] = @as(u8, @intCast(@min(literals, 15))) << 4 | @as(u8, @intCast(@min(length - 4, 15)));
            used += 1;
            if (literals >= 15) writeLength(output, &used, literals - 15);
            @memcpy(output[used..][0..literals], input[anchor..pos]);
            used += literals;
            std.mem.writeInt(u16, output[used..][0..2], @intCast(pos - previous), .little);
            used += 2;
            if (length >= 19) writeLength(output, &used, length - 19);
            pos += length;
            anchor = pos;
        }
        const literals = input.len - anchor;
        output[used] = @as(u8, @intCast(@min(literals, 15))) << 4;
        used += 1;
        if (literals >= 15) writeLength(output, &used, literals - 15);
        @memcpy(output[used..][0..literals], input[anchor..]);
        return output[0 .. used + literals];
    }
};

pub fn validate(input: []const u8, raw_len: usize) Error!void {
    try decodeBlock(input, raw_len, null);
}

/// Input and output must not overlap.
pub fn decompress(input: []const u8, output: []u8, raw_len: usize) Error![]u8 {
    if (output.len < raw_len) return error.BufferTooSmall;
    try decodeBlock(input, raw_len, output);
    return output[0..raw_len];
}

fn decodeBlock(input: []const u8, raw_len: usize, output: ?[]u8) Error!void {
    if (raw_len > max_size or input.len > try bound(max_size)) return error.InvalidLength;
    var read: usize = 0;
    var written: usize = 0;
    var last_match: ?usize = null;
    while (read < input.len) {
        const token = input[read];
        read += 1;
        const literals = try readLength(input, &read, token >> 4);
        if (literals > input.len - read or literals > raw_len - written) return error.InvalidCompressedData;
        if (output) |bytes| @memcpy(bytes[written..][0..literals], input[read..][0..literals]);
        read += literals;
        written += literals;
        if (read == input.len) {
            if (written != raw_len) return error.InvalidCompressedData;
            if (last_match) |start| {
                if (literals < 5 or written - start < 12) return error.InvalidCompressedData;
            }
            return;
        }
        if (input.len - read < 2) return error.InvalidCompressedData;
        const offset = std.mem.readInt(u16, input[read..][0..2], .little);
        read += 2;
        if (offset == 0 or offset > written) return error.InvalidCompressedData;
        const length = try readLength(input, &read, token & 15) + 4;
        if (length > raw_len - written) return error.InvalidCompressedData;
        last_match = written;
        if (output) |bytes| {
            const source = written - offset;
            var copied: usize = 0;
            while (copied < length) {
                const n = @min(length - copied, offset + copied);
                @memcpy(bytes[written + copied ..][0..n], bytes[source..][0..n]);
                copied += n;
            }
        }
        written += length;
    }
    return error.InvalidCompressedData;
}

fn readLength(input: []const u8, position: *usize, initial: u8) Error!usize {
    var length: usize = initial;
    if (initial != 15) return length;
    while (true) {
        if (position.* == input.len) return error.InvalidCompressedData;
        const extra = input[position.*];
        position.* += 1;
        if (length > max_size - extra) return error.InvalidCompressedData;
        length += extra;
        if (extra != 255) return length;
    }
}

fn writeLength(output: []u8, position: *usize, size: usize) void {
    var remaining = size;
    while (remaining >= 255) : (remaining -= 255) {
        output[position.*] = 255;
        position.* += 1;
    }
    output[position.*] = @intCast(remaining);
    position.* += 1;
}
