const db = @import("zigritedb");

pub const header: db.segment.Header = .{
    .segment_id = 1,
    .generation = 1,
    .region = .{ .dimension = 0, .x = 0, .z = 0 },
};
pub const options: db.shard.Options = .{
    .max_keys = 32,
    .max_segment_size = 4096,
    .batch_buffer_size = 1024,
};

pub fn item(id: u64, x: i32, value: ?[]const u8) db.entry.Entry {
    const bytes = value orelse "";

    return .{
        .header = .{
            .kind = if (value == null) .delete else .put,
            .batch_id = id,
            .stored_len = @intCast(bytes.len),
            .raw_len = @intCast(bytes.len),
        },
        .key = .{ .dimension = 0, .chunk_x = x, .chunk_z = 0, .component = .metadata },
        .value = bytes,
    };
}

pub const Device = struct {
    bytes: [4096]u8 = undefined,
    used: usize = 0,
    synced_len: usize = 0,
    fail_write: bool = false,
    fail_sync: bool = false,

    pub fn length(self: *Device) !u64 {
        return self.used;
    }

    pub fn readExact(self: *Device, output: []u8, offset: u64) !void {
        if (offset > self.used or output.len > self.used - offset) return error.UnexpectedEndOfFile;

        const start: usize = @intCast(offset);
        @memcpy(output, self.bytes[start..][0..output.len]);
    }

    pub fn writeAll(self: *Device, bytes: []const u8, offset: u64) !void {
        const start: usize = @intCast(offset);
        const len = if (self.fail_write) bytes.len / 2 else bytes.len;
        @memcpy(self.bytes[start..][0..len], bytes[0..len]);
        self.used = @max(self.used, start + len);

        if (self.fail_write) return error.NoSpaceLeft;
    }

    pub fn sync(self: *Device) !void {
        if (self.fail_sync) return error.InputOutput;
        self.synced_len = self.used;
    }
};
