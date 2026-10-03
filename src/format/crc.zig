const std = @import("std");
const builtin = @import("builtin");

/// CRC-32C, using the CPU's instruction when it has one.
pub const Implementation = enum { hardware, software };

const native = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .crc32),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
    else => false,
};

const Update = *const fn (u32, []const u8) u32;

// Picks the implementation on first use.
var selected: std.atomic.Value(Update) = .init(&resolve);

pub fn hash(bytes: []const u8) u32 {
    return ~update(0xffff_ffff, bytes);
}

/// Start from 0xffff_ffff and invert the result.
pub inline fn update(crc: u32, bytes: []const u8) u32 {
    if (native) return hardware(crc, bytes);
    return selected.load(.monotonic)(crc, bytes);
}

pub fn implementation() Implementation {
    return if (native or detect()) .hardware else .software;
}

fn resolve(crc: u32, bytes: []const u8) u32 {
    const chosen: Update = if (detect()) &hardware else &software;
    selected.store(chosen, .monotonic);
    return chosen(crc, bytes);
}

fn detect() bool {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // SSE4.2, which has crc32.
            var ecx: u32 = undefined;
            asm volatile ("cpuid"
                : [_] "={ecx}" (ecx),
                : [_] "{eax}" (@as(u32, 1)),
                  [_] "{ecx}" (@as(u32, 0)),
                : .{ .eax = true, .ebx = true, .edx = true });
            return ecx & (1 << 20) != 0;
        },
        .aarch64 => return switch (builtin.os.tag) {
            .linux => std.os.linux.getauxval(std.elf.AT_HWCAP) & (1 << 7) != 0,
            .macos, .ios => true,
            else => false,
        },
        else => return false,
    }
}

pub fn hardware(initial: u32, bytes: []const u8) u32 {
    var crc: u64 = initial;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) crc = step64(crc, std.mem.readInt(u64, bytes[i..][0..8], .little));
    // Zig's own backend can't encode crc32b, so tails use the table.
    return software(@truncate(crc), bytes[i..]);
}

inline fn step64(crc: u64, value: u64) u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm ("crc32q %[value], %[crc]"
            : [crc] "=r" (-> u64),
            : [value] "r" (value),
              [_] "0" (crc),
        ),
        .aarch64 => asm (".arch_extension crc\ncrc32cx %w[crc], %w[crc], %[value]"
            : [crc] "=r" (-> u64),
            : [value] "r" (value),
              [_] "0" (crc),
        ),
        else => unreachable,
    };
}

const tables = blk: {
    @setEvalBranchQuota(20000);
    var result: [8][256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = i;
        for (0..8) |_| crc = if (crc & 1 != 0) (crc >> 1) ^ 0x82f63b78 else crc >> 1;
        result[0][i] = crc;
    }
    for (0..256) |i| {
        for (1..8) |t| result[t][i] = (result[t - 1][i] >> 8) ^ result[0][result[t - 1][i] & 0xff];
    }
    break :blk result;
};

pub fn software(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const low = std.mem.readInt(u32, bytes[i..][0..4], .little) ^ crc;
        const high = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        crc = tables[7][low & 0xff] ^ tables[6][(low >> 8) & 0xff] ^ tables[5][(low >> 16) & 0xff] ^ tables[4][low >> 24] ^
            tables[3][high & 0xff] ^ tables[2][(high >> 8) & 0xff] ^ tables[1][(high >> 16) & 0xff] ^ tables[0][high >> 24];
    }
    while (i < bytes.len) : (i += 1) crc = tables[0][(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
    return crc;
}

test "every implementation matches the reference CRC-32C for each length and alignment" {
    var bytes: [300]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    const has_hardware = implementation() == .hardware;
    for (0..bytes.len) |len| {
        for (0..@min(9, bytes.len - len + 1)) |start| {
            const slice = bytes[start..][0..len];
            const expected = std.hash.crc.Crc32Iscsi.hash(slice);
            try std.testing.expectEqual(expected, hash(slice));
            try std.testing.expectEqual(expected, ~software(0xffff_ffff, slice));
            if (has_hardware) try std.testing.expectEqual(expected, ~hardware(0xffff_ffff, slice));
        }
    }
    try std.testing.expectEqual(@as(u32, 0xe3069283), hash("123456789"));
}

test "updates chain across splits" {
    const text = "the quick brown fox jumps over the lazy dog";
    for (0..text.len) |split| {
        try std.testing.expectEqual(hash(text), ~update(update(0xffff_ffff, text[0..split]), text[split..]));
    }
}
