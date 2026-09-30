const std = @import("std");
const builtin = @import("builtin");

const Software = std.hash.crc.Crc32Iscsi;

// Baseline x86_64 builds fall back to the slow table; build with -Dcpu=x86_64_v2.
const hardware = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .crc32),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
    else => false,
};

pub fn hash(bytes: []const u8) u32 {
    if (!hardware) return Software.hash(bytes);
    return ~update(0xffff_ffff, bytes);
}

fn update(initial: u32, bytes: []const u8) u32 {
    var crc: u64 = initial;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) crc = step64(crc, std.mem.readInt(u64, bytes[i..][0..8], .little));
    var tail: Software = .{ .crc = @intCast(crc) };
    tail.update(bytes[i..]);
    return tail.crc;
}

inline fn step64(crc: u64, value: u64) u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm ("crc32q %[value], %[crc]"
            : [crc] "=r" (-> u64),
            : [value] "r" (value),
              [_] "0" (crc),
        ),
        .aarch64 => asm ("crc32cx %w[crc], %w[crc], %[value]"
            : [crc] "=r" (-> u64),
            : [value] "r" (value),
              [_] "0" (crc),
        ),
        else => unreachable,
    };
}

test "matches the software CRC-32C for every length and alignment" {
    var bytes: [300]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    for (0..bytes.len) |len| {
        for (0..@min(9, bytes.len - len + 1)) |start| {
            const slice = bytes[start..][0..len];
            try std.testing.expectEqual(Software.hash(slice), hash(slice));
        }
    }
    try std.testing.expectEqual(@as(u32, 0xe3069283), hash("123456789"));
}
