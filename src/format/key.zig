const std = @import("std");

/// Bedrock chunk record tags. Any other tag byte is stored as-is.
pub const Component = enum(u8) {
    data3d = 0x2b,
    version = 0x2c,
    data2d = 0x2d,
    data2d_legacy = 0x2e,
    subchunk = 0x2f,
    legacy_terrain = 0x30,
    block_entities = 0x31,
    entities = 0x32,
    pending_ticks = 0x33,
    legacy_block_extra_data = 0x34,
    biome_state = 0x35,
    finalized_state = 0x36,
    conversion_data = 0x37,
    border_blocks = 0x38,
    hardcoded_spawners = 0x39,
    random_ticks = 0x3a,
    checksums = 0x3b,
    generation_seed = 0x3c,
    pre_caves_blending = 0x3d,
    blending_biome_height = 0x3e,
    metadata_hash = 0x3f,
    blending_data = 0x40,
    actor_digest_version = 0x41,
    legacy_version = 0x76,
    /// Bedrock keeps this outside chunk keys as "digp"; Zigrite stores it with the chunk.
    actor_digest = 0x80,
    _,
};

pub const Region = struct {
    dimension: i32,
    x: i32,
    z: i32,

    pub fn eql(a: Region, b: Region) bool {
        return a.dimension == b.dimension and a.x == b.x and a.z == b.z;
    }
};

pub const KeyFilter = struct {
    /// Bit `i` keeps component `i`; all set by default.
    components: [8]u32 = @splat(0xffff_ffff),
    min_chunk_x: i32 = std.math.minInt(i32),
    max_chunk_x: i32 = std.math.maxInt(i32),
    min_chunk_z: i32 = std.math.minInt(i32),
    max_chunk_z: i32 = std.math.maxInt(i32),

    pub fn only(components: []const Component) KeyFilter {
        var filter: KeyFilter = .{ .components = @splat(0) };
        for (components) |c| filter.components[@intFromEnum(c) >> 5] |= @as(u32, 1) << @intCast(@intFromEnum(c) & 31);
        return filter;
    }

    pub fn matches(self: KeyFilter, key: Key) bool {
        const c = @intFromEnum(key.component);
        return self.components[c >> 5] & (@as(u32, 1) << @intCast(c & 31)) != 0 and
            key.chunk_x >= self.min_chunk_x and key.chunk_x <= self.max_chunk_x and
            key.chunk_z >= self.min_chunk_z and key.chunk_z <= self.max_chunk_z;
    }
};

pub fn keyLessThan(_: void, a: Key, b: Key) bool {
    if (a.dimension != b.dimension) return a.dimension < b.dimension;
    if (a.chunk_x != b.chunk_x) return a.chunk_x < b.chunk_x;
    if (a.chunk_z != b.chunk_z) return a.chunk_z < b.chunk_z;
    return a.local() < b.local();
}

pub const Key = struct {
    dimension: i32,
    chunk_x: i32,
    chunk_z: i32,
    component: Component,
    subchunk_y: i32 = 0,

    pub const Error = error{InvalidSubchunkY};

    /// Only subchunks have a Y, which Bedrock stores as one signed byte.
    pub fn validate(self: Key) Error!void {
        const ok = if (self.component == .subchunk)
            self.subchunk_y >= std.math.minInt(i8) and self.subchunk_y <= std.math.maxInt(i8)
        else
            self.subchunk_y == 0;
        if (!ok) return error.InvalidSubchunkY;
    }

    pub fn region(self: Key) Region {
        return .{
            .dimension = self.dimension,
            .x = self.chunk_x >> 5,
            .z = self.chunk_z >> 5,
        };
    }

    /// Chunk position inside its region, 0..1023.
    pub fn slot(self: Key) u10 {
        return @intCast((self.chunk_z & 31) * 32 + (self.chunk_x & 31));
    }

    /// Orders by component, then signed Y. Assumes a validated key.
    pub fn local(self: Key) u16 {
        return localKey(self.component, @intCast(self.subchunk_y));
    }

    pub fn fromLocal(region_: Region, chunk_slot: u10, value: u16) Key {
        const component: Component = @enumFromInt(value >> 8);
        const y: i8 = @bitCast(@as(u8, @truncate(value)) ^ 0x80);
        return .{
            .dimension = region_.dimension,
            .chunk_x = region_.x * 32 + @as(i32, chunk_slot % 32),
            .chunk_z = region_.z * 32 + @as(i32, chunk_slot / 32),
            .component = component,
            .subchunk_y = y,
        };
    }
};

pub fn localKey(component: Component, y: i8) u16 {
    return @as(u16, @intFromEnum(component)) << 8 | (@as(u8, @bitCast(y)) ^ 0x80);
}

test "region and slot use floor division for negative coordinates" {
    const key: Key = .{ .dimension = 1, .chunk_x = -1, .chunk_z = -33, .component = .version };
    try std.testing.expectEqual(Region{ .dimension = 1, .x = -1, .z = -2 }, key.region());
    try std.testing.expectEqual(@as(u10, 31 * 32 + 31), key.slot());
    const back = Key.fromLocal(key.region(), key.slot(), key.local());
    try std.testing.expectEqual(key, back);
}

test "local keys keep signed subchunk order" {
    const low = localKey(.subchunk, -4);
    const high = localKey(.subchunk, 3);
    try std.testing.expect(low < high);
    try std.testing.expect(localKey(.data3d, 127) < low);
}
