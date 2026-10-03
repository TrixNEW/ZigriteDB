//! Micro-benchmarks for single components: CRC dispatch, LZ4 on real values, and the
//! dense region index against the v1-style hash map. Run with
//! `zig build micro -Doptimize=ReleaseFast -- [dataset.zgds]`.
const std = @import("std");
const db = @import("zigritedb");

const Timer = struct {
    io: std.Io,
    start: std.Io.Clock.Timestamp,

    fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.Timestamp.now(io, .awake) };
    }

    fn seconds(self: Timer) f64 {
        return @as(f64, @floatFromInt(self.start.untilNow(self.io).raw.nanoseconds)) / 1e9;
    }
};

var sink: u64 = 0;

fn crcBench(io: std.Io, out: *std.Io.Writer) !void {
    var bytes: [65536]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
    const has_hardware = db.crc.implementation() == .hardware;
    try out.print("\"crc\":{{\"hardware_available\":{},\"sizes\":[", .{has_hardware});
    for ([_]usize{ 16, 64, 256, 1024, 4096, 16384, 65536 }, 0..) |size, n| {
        const rounds = 256 * 1024 * 1024 / size;
        var t = Timer.begin(io);
        for (0..rounds) |i| sink +%= db.crc.software(@truncate(i), bytes[0..size]);
        const software = @as(f64, @floatFromInt(rounds * size)) / t.seconds() / 1e9;
        var hardware: f64 = 0;
        if (has_hardware) {
            t = Timer.begin(io);
            for (0..rounds) |i| sink +%= db.crc.hardware(@truncate(i), bytes[0..size]);
            hardware = @as(f64, @floatFromInt(rounds * size)) / t.seconds() / 1e9;
        }
        t = Timer.begin(io);
        for (0..rounds) |i| sink +%= db.crc.update(@truncate(i), bytes[0..size]);
        const dispatched = @as(f64, @floatFromInt(rounds * size)) / t.seconds() / 1e9;
        try out.print("{s}{{\"bytes\":{},\"software_gbps\":{d:.2},\"hardware_gbps\":{d:.2},\"dispatched_gbps\":{d:.2}}}", .{ if (n == 0) "" else ",", size, software, hardware, dispatched });
    }
    try out.writeAll("]}");
}

const Value = struct { len: u32, bytes: []const u8 };

fn loadSubchunks(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Value {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    var list: std.ArrayListUnmanaged(Value) = .empty;
    var p: usize = 8;
    const chunks = std.mem.readInt(u32, data[4..8], .little);
    for (0..chunks) |_| {
        const count = std.mem.readInt(u16, data[p + 8 ..][0..2], .little);
        p += 10;
        for (0..count) |_| {
            const tag = data[p];
            const len = std.mem.readInt(u32, data[p + 2 ..][0..4], .little);
            if (tag == 0x2f) try list.append(allocator, .{ .len = len, .bytes = data[p + 6 ..][0..len] });
            p += 6 + len;
        }
    }
    return list.toOwnedSlice(allocator);
}

fn lz4Bench(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, path: []const u8) !void {
    const values = try loadSubchunks(allocator, io, path);
    var encoder: db.lz4.Encoder = .{};
    var compressed = try allocator.alloc(u8, 32 * 1024 * 1024);
    var offsets = try allocator.alloc(usize, values.len + 1);
    var output: [1 << 20]u8 = undefined;
    var raw: usize = 0;
    var t = Timer.begin(io);
    var at: usize = 0;
    for (values, 0..) |value, i| {
        offsets[i] = at;
        if (at + value.len * 2 + 64 > compressed.len) break;
        at += (try encoder.compress(value.bytes, compressed[at..])).len;
        raw += value.len;
    }
    offsets[values.len] = at;
    const compress = @as(f64, @floatFromInt(raw)) / t.seconds() / 1e6;
    t = Timer.begin(io);
    for (values, 0..) |value, i| {
        const stored = compressed[offsets[i]..offsets[i + 1]];
        sink +%= (try db.lz4.decompress(stored, &output, value.len)).len;
    }
    const decompress = @as(f64, @floatFromInt(raw)) / t.seconds() / 1e6;
    try out.print(",\"lz4_subchunks\":{{\"values\":{},\"ratio\":{d:.3},\"compress_mbps\":{d:.0},\"decompress_mbps\":{d:.0}}}", .{ values.len, @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(raw)), compress, decompress });
}

/// The v1 index: packed u64 keys in a hash map of 32-byte locations.
const OldLocation = struct { offset: u64, batch_id: u64, stored_len: u32, raw_len: u32, fingerprint: u32, segment: u16 };

fn indexBench(allocator: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    // A full region: 1024 chunks with 24 subchunks and 8 other components each.
    const per_chunk = 32;
    const total = 1024 * per_chunk;
    var keys = try allocator.alloc(struct { slot: u10, local: u16 }, total);
    defer allocator.free(keys);
    for (0..1024) |slot| {
        for (0..per_chunk) |c| {
            const local = if (c < 24) db.key.localKey(.subchunk, @intCast(@as(i32, @intCast(c)) - 4)) else db.key.localKey(@enumFromInt(0x31 + c - 24), 0);
            keys[slot * per_chunk + c] = .{ .slot = @intCast(slot), .local = local };
        }
    }
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().shuffle(@TypeOf(keys[0]), keys);
    const location: db.index.Location = .{ .batch_id = 1, .offset = 48, .stored_len = 100, .raw_len = 100, .fingerprint = 0, .segment = 0, .compression = .none };

    var counting: CountingAllocator = .{ .parent = allocator };
    var t = Timer.begin(io);
    var dense = try db.index.Index.init(counting.allocator(), .{ .dimension = 0, .x = 0, .z = 0 }, 1, total);
    for (keys) |k| try dense.restore(k.slot, k.local, location);
    const dense_build = t.seconds();
    const dense_bytes = counting.peak;
    t = Timer.begin(io);
    const lookups = 4_000_000;
    for (0..lookups) |i| {
        const k = keys[i % total];
        sink +%= dense.lookup(k.slot, k.local).?.stored_len;
    }
    const dense_lookup = t.seconds();
    var entries: [64]db.index.Entry = undefined;
    t = Timer.begin(io);
    for (0..lookups / per_chunk) |i| sink +%= dense.chunkEntries(@truncate(i), &entries);
    const dense_chunk = t.seconds();
    dense.deinit();

    var old_counting: CountingAllocator = .{ .parent = allocator };
    t = Timer.begin(io);
    var map: std.AutoHashMapUnmanaged(u64, OldLocation) = .empty;
    for (keys) |k| try map.put(old_counting.allocator(), @as(u64, k.slot) << 16 | k.local, .{ .offset = 48, .batch_id = 1, .stored_len = 100, .raw_len = 100, .fingerprint = 0, .segment = 0 });
    const map_build = t.seconds();
    const map_bytes = old_counting.peak;
    t = Timer.begin(io);
    for (0..lookups) |i| {
        const k = keys[i % total];
        sink +%= map.get(@as(u64, k.slot) << 16 | k.local).?.stored_len;
    }
    const map_lookup = t.seconds();
    // A chunk read in v1 looks up each component it wants.
    t = Timer.begin(io);
    for (0..lookups / per_chunk) |i| {
        const slot: u64 = @as(u10, @truncate(i));
        for (0..per_chunk) |c| sink +%= if (map.get(slot << 16 | keys[c].local)) |v| v.stored_len else 0;
    }
    const map_chunk = t.seconds();
    map.deinit(old_counting.allocator());

    const ns = 1e9 / @as(f64, lookups);
    try out.print(",\"index\":{{\"entries\":{},\"dense\":{{\"build_ms\":{d:.2},\"bytes\":{},\"lookup_ns\":{d:.1},\"chunk_ns\":{d:.1}}},\"hash_map\":{{\"build_ms\":{d:.2},\"bytes\":{},\"lookup_ns\":{d:.1},\"chunk_ns\":{d:.1}}}}}", .{
        total,
        dense_build * 1e3,
        dense_bytes,
        dense_lookup * ns,
        dense_chunk * ns * per_chunk,
        map_build * 1e3,
        map_bytes,
        map_lookup * ns,
        map_chunk * ns * per_chunk,
    });
}

/// Tracks the peak bytes held, to compare index memory.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    held: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.held += len;
        self.peak = @max(self.peak, self.held);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret)) return false;
        self.held = self.held - memory.len + new_len;
        self.peak = @max(self.peak, self.held);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret) orelse return null;
        self.held = self.held - memory.len + new_len;
        self.peak = @max(self.peak, self.held);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.held -= memory.len;
        self.parent.rawFree(memory, alignment, ret);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try out.writeAll("{");
    try crcBench(io, out);
    try indexBench(allocator, io, out);
    if (args.len > 1) try lz4Bench(init.arena.allocator(), io, out, args[1]);
    try out.print(",\"sink\":{}}}\n", .{sink % 2});
    try out.flush();
}
