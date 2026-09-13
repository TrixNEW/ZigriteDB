const std = @import("std");
const transfer = @import("zigritedb").storage.transfer;
const testing = std.testing;

const Device = struct {
    bytes: [8]u8 = [_]u8{0} ** 8,
    step: usize = 2,
    fail_at: ?u64 = null,
    calls: usize = 0,

    pub fn readSome(self: *Device, output: []u8, offset: u64) !usize {
        self.calls += 1;
        if (self.fail_at) |limit| if (offset >= limit) return error.InputOutput;
        const start: usize = @intCast(offset);
        const count = @min(self.step, output.len, self.bytes.len - start);
        @memcpy(output[0..count], self.bytes[start..][0..count]);
        return count;
    }

    pub fn writeSome(self: *Device, input: []const u8, offset: u64) !usize {
        self.calls += 1;
        if (self.fail_at) |limit| if (offset >= limit) return error.NoSpaceLeft;
        const start: usize = @intCast(offset);
        const count = @min(self.step, input.len, self.bytes.len - start);
        @memcpy(self.bytes[start..][0..count], input[0..count]);
        return count;
    }
};

test "short transfers finish at the right offsets" {
    var device: Device = .{};
    try transfer.writeAll(&device, "abcdef", 1);
    var output: [6]u8 = undefined;
    try transfer.readExact(&device, &output, 1);
    try testing.expectEqualStrings("abcdef", &output);
    try testing.expectEqual(@as(usize, 6), device.calls);
}

test "stalled transfers stop" {
    var device: Device = .{ .step = 0 };
    var output: [1]u8 = undefined;
    try testing.expectError(error.NoProgress, transfer.writeAll(&device, "x", 0));
    try testing.expectError(error.UnexpectedEndOfFile, transfer.readExact(&device, &output, 0));
}

test "disk errors after a partial transfer are returned" {
    var device: Device = .{ .fail_at = 2 };
    try testing.expectError(error.NoSpaceLeft, transfer.writeAll(&device, "abcd", 0));
    try testing.expectEqualStrings("ab", device.bytes[0..2]);
    var output = [_]u8{0xaa} ** 4;
    try testing.expectError(error.InputOutput, transfer.readExact(&device, &output, 0));
    try testing.expectEqualSlices(u8, &.{ 'a', 'b', 0xaa, 0xaa }, &output);
}

test "overflow and empty transfers never touch the device" {
    var device: Device = .{};
    var output: [2]u8 = undefined;
    try testing.expectError(error.InvalidOffset, transfer.readExact(&device, &output, std.math.maxInt(u64)));
    try testing.expectError(error.InvalidOffset, transfer.writeAll(&device, "xx", std.math.maxInt(u64)));
    try transfer.readExact(&device, output[0..0], 0);
    try transfer.writeAll(&device, "", 0);
    try testing.expectEqual(@as(usize, 0), device.calls);
}
