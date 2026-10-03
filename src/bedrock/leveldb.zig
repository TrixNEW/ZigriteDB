const std = @import("std");
const flate = std.compress.flate;

const crc = @import("../format/crc.zig");
const File = @import("../io/file.zig").File;

const block_size = 32 * 1024;
const table_magic: u64 = 0xdb4775248b80fb57;
const footer_len = 48;

pub const Compression = enum(u8) { none = 0, zlib = 2, zlib_raw = 4 };

fn mask(value: u32) u32 {
    return ((value >> 15) | (value << 17)) +% 0xa282ead8;
}

fn unmask(value: u32) u32 {
    const rotated = value -% 0xa282ead8;
    return (rotated >> 17) | (rotated << 15);
}

fn varint(bytes: []const u8, at: *usize) !u64 {
    var result: u64 = 0;
    var shift: u7 = 0;
    while (shift < 64) : (shift += 7) {
        if (at.* >= bytes.len) return error.Corrupt;
        const byte = bytes[at.*];
        at.* += 1;
        result |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return result;
    }
    return error.Corrupt;
}

fn slice(bytes: []const u8, at: *usize) ![]const u8 {
    const len = try varint(bytes, at);
    if (len > bytes.len - at.*) return error.Corrupt;
    defer at.* += @intCast(len);
    return bytes[at.*..][0..@intCast(len)];
}

fn putVarint(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try list.append(allocator, @as(u8, @truncate(v)) | 0x80);
    try list.append(allocator, @truncate(v));
}

fn putSlice(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try putVarint(list, allocator, bytes.len);
    try list.appendSlice(allocator, bytes);
}

/// A torn record ends the log, like LevelDB.
pub const LogReader = struct {
    bytes: []const u8,
    at: usize = 0,
    record: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *LogReader, allocator: std.mem.Allocator) void {
        self.record.deinit(allocator);
    }

    pub fn next(self: *LogReader, allocator: std.mem.Allocator) !?[]const u8 {
        self.record.clearRetainingCapacity();
        var started = false;
        while (true) {
            const left_in_block = block_size - self.at % block_size;
            if (left_in_block < 7) self.at += left_in_block;
            if (self.bytes.len - self.at < 7) return null;
            const header = self.bytes[self.at..][0..7];
            const len = std.mem.readInt(u16, header[4..6], .little);
            const kind = header[6];
            if (kind == 0 and len == 0) {
                self.at += left_in_block;
                continue;
            }
            if (self.bytes.len - self.at - 7 < len or 7 + @as(usize, len) > left_in_block) return null;
            const data = self.bytes[self.at + 7 ..][0..len];
            if (unmask(std.mem.readInt(u32, header[0..4], .little)) != ~crc.update(crc.update(0xffff_ffff, header[6..7]), data)) return null;
            self.at += 7 + len;
            switch (kind) {
                1 => return data,
                2 => {
                    self.record.clearRetainingCapacity();
                    try self.record.appendSlice(allocator, data);
                    started = true;
                },
                3, 4 => {
                    if (!started) continue;
                    try self.record.appendSlice(allocator, data);
                    if (kind == 4) return self.record.items;
                },
                else => return null,
            }
        }
    }
};

pub const LogWriter = struct {
    file: File,
    offset: u64 = 0,

    pub fn add(self: *LogWriter, record: []const u8) !void {
        var rest = record;
        var first = true;
        while (true) {
            const left_in_block = block_size - self.offset % block_size;
            if (left_in_block < 7) {
                const zeros = [_]u8{0} ** 7;
                try self.file.writeAll(zeros[0..@intCast(left_in_block)], self.offset);
                self.offset += left_in_block;
                continue;
            }
            const room: usize = @intCast(left_in_block - 7);
            const len = @min(room, rest.len);
            const last = len == rest.len;
            const kind: u8 = if (first and last) 1 else if (first) 2 else if (last) 4 else 3;
            var header: [7]u8 = undefined;
            std.mem.writeInt(u16, header[4..6], @intCast(len), .little);
            header[6] = kind;
            std.mem.writeInt(u32, header[0..4], mask(~crc.update(crc.update(0xffff_ffff, header[6..7]), rest[0..len])), .little);
            try self.file.writeAll(&header, self.offset);
            try self.file.writeAll(rest[0..len], self.offset + 7);
            self.offset += 7 + len;
            rest = rest[len..];
            first = false;
            if (last) return;
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) void {
    var version: Version = .{};
    version.apply(allocator, bytes) catch {};
    var key: std.ArrayListUnmanaged(u8) = .empty;
    defer key.deinit(allocator);
    const end = TableIterator.restartsStart(bytes) catch return;
    var at: usize = 0;
    while (at < end) _ = TableIterator.entry(bytes, &at, &key, allocator) catch return;
}

const FileMeta = struct {
    level: u32,
    number: u64,
    smallest: []const u8,
};

const Version = struct {
    log_number: u64 = 0,
    prev_log_number: u64 = 0,
    files: std.AutoArrayHashMapUnmanaged(u64, FileMeta) = .empty,

    fn apply(self: *Version, allocator: std.mem.Allocator, edit: []const u8) !void {
        var at: usize = 0;
        while (at < edit.len) {
            switch (try varint(edit, &at)) {
                1 => if (!std.mem.eql(u8, try slice(edit, &at), "leveldb.BytewiseComparator")) return error.UnsupportedComparator,
                2 => self.log_number = try varint(edit, &at),
                3, 4 => _ = try varint(edit, &at),
                5 => {
                    _ = try varint(edit, &at);
                    _ = try slice(edit, &at);
                },
                6 => {
                    _ = try varint(edit, &at);
                    _ = self.files.swapRemove(try varint(edit, &at));
                },
                7 => {
                    const level = std.math.cast(u32, try varint(edit, &at)) orelse return error.Corrupt;
                    const number = try varint(edit, &at);
                    _ = try varint(edit, &at);
                    const smallest = try allocator.dupe(u8, try slice(edit, &at));
                    _ = try slice(edit, &at);
                    try self.files.put(allocator, number, .{ .level = level, .number = number, .smallest = smallest });
                },
                9 => self.prev_log_number = try varint(edit, &at),
                else => return error.Corrupt,
            }
        }
    }
};

pub fn decompress(allocator: std.mem.Allocator, kind: u8, data: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    out.clearRetainingCapacity();
    const container: flate.Container = switch (kind) {
        0 => return out.appendSlice(allocator, data),
        2 => .zlib,
        4 => .raw,
        else => return error.UnsupportedCompression,
    };
    var input: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&input, container, &window);
    var writer: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = writer.toArrayList();
    _ = inflate.reader.streamRemaining(&writer.writer) catch return error.Corrupt;
}

const TableIterator = struct {
    file: File,
    index: std.ArrayListUnmanaged(u8) = .empty,
    index_at: usize = 0,
    index_end: usize = 0,
    block: std.ArrayListUnmanaged(u8) = .empty,
    raw: std.ArrayListUnmanaged(u8) = .empty,
    block_at: usize = 0,
    block_end: usize = 0,
    key: std.ArrayListUnmanaged(u8) = .empty,
    index_key: std.ArrayListUnmanaged(u8) = .empty,
    value: []const u8 = &.{},

    fn open(allocator: std.mem.Allocator, file: File) !TableIterator {
        var self: TableIterator = .{ .file = file };
        errdefer self.deinit(allocator);
        const length = try file.length();
        if (length < footer_len) return error.Corrupt;
        var footer: [footer_len]u8 = undefined;
        try file.readExact(&footer, length - footer_len);
        if (std.mem.readInt(u64, footer[40..48], .little) != table_magic) return error.Corrupt;
        var at: usize = 0;
        _ = try varint(&footer, &at);
        _ = try varint(&footer, &at);
        const offset = try varint(&footer, &at);
        const size = try varint(&footer, &at);
        try self.readBlock(allocator, offset, size, &self.index);
        self.index_end = try restartsStart(self.index.items);
        return self;
    }

    fn deinit(self: *TableIterator, allocator: std.mem.Allocator) void {
        self.index.deinit(allocator);
        self.block.deinit(allocator);
        self.raw.deinit(allocator);
        self.key.deinit(allocator);
        self.index_key.deinit(allocator);
        self.file.handle.close(self.file.io);
    }

    fn readBlock(self: *TableIterator, allocator: std.mem.Allocator, offset: u64, size: u64, out: *std.ArrayListUnmanaged(u8)) !void {
        if (size > 64 * 1024 * 1024) return error.Corrupt;
        try self.raw.resize(allocator, @intCast(size + 5));
        try self.file.readExact(self.raw.items, offset);
        const n: usize = @intCast(size);
        const expected = unmask(std.mem.readInt(u32, self.raw.items[n + 1 ..][0..4], .little));
        if (expected != crc.hash(self.raw.items[0 .. n + 1])) return error.ChecksumMismatch;
        try decompress(allocator, self.raw.items[n], self.raw.items[0..n], out);
    }

    fn restartsStart(block: []const u8) !usize {
        if (block.len < 4) return error.Corrupt;
        const restarts = std.mem.readInt(u32, block[block.len - 4 ..][0..4], .little);
        const trailer = (@as(usize, restarts) + 1) * 4;
        if (trailer > block.len) return error.Corrupt;
        return block.len - trailer;
    }

    fn entry(block: []const u8, at: *usize, key: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) ![]const u8 {
        const shared = try varint(block, at);
        const unshared = try varint(block, at);
        const value_len = try varint(block, at);
        if (shared > key.items.len or unshared > block.len - at.*) return error.Corrupt;
        key.shrinkRetainingCapacity(@intCast(shared));
        try key.appendSlice(allocator, block[at.*..][0..@intCast(unshared)]);
        at.* += @intCast(unshared);
        if (value_len > block.len - at.*) return error.Corrupt;
        defer at.* += @intCast(value_len);
        return block[at.*..][0..@intCast(value_len)];
    }

    fn next(self: *TableIterator, allocator: std.mem.Allocator) !bool {
        while (self.block_at >= self.block_end) {
            if (self.index_at >= self.index_end) return false;
            const handle = try entry(self.index.items, &self.index_at, &self.index_key, allocator);
            var at: usize = 0;
            const offset = try varint(handle, &at);
            const size = try varint(handle, &at);
            try self.readBlock(allocator, offset, size, &self.block);
            self.block_end = try restartsStart(self.block.items);
            self.block_at = 0;
            self.key.clearRetainingCapacity();
        }
        self.value = try entry(self.block.items, &self.block_at, &self.key, allocator);
        if (self.key.items.len < 8) return error.Corrupt;
        return true;
    }
};

const Source = struct {
    tables: []const u64 = &.{},
    position: usize = 0,
    table: ?TableIterator = null,
    memtable: []const Memo = &.{},
    memo_at: usize = 0,
    key: []const u8 = &.{},
    sequence: u64 = 0,
    value: ?[]const u8 = null,
    done: bool = false,
};

const Memo = struct {
    key: []const u8,
    sequence: u64,
    value: ?[]const u8,

    fn lessThan(_: void, a: Memo, b: Memo) bool {
        return switch (std.mem.order(u8, a.key, b.key)) {
            .lt => true,
            .gt => false,
            .eq => a.sequence > b.sequence,
        };
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    arena: std.heap.ArenaAllocator,
    sources: []Source,
    last_key: std.ArrayListUnmanaged(u8) = .empty,
    value: std.ArrayListUnmanaged(u8) = .empty,
    started: bool = false,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Reader {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const scratch = arena.allocator();

        var current_buffer: [256]u8 = undefined;
        const current = std.mem.trimEnd(u8, try dir.readFile(io, "CURRENT", &current_buffer), "\n");
        if (!std.mem.startsWith(u8, current, "MANIFEST-") or std.mem.indexOfScalar(u8, current, '/') != null) return error.Corrupt;
        const manifest_bytes = try dir.readFileAlloc(io, current, scratch, .limited(1 << 30));
        var version: Version = .{};
        var log: LogReader = .{ .bytes = manifest_bytes };
        while (try log.next(scratch)) |edit| try version.apply(scratch, edit);

        // Unflushed writes live in logs from the manifest's log number on.
        var logs: std.ArrayListUnmanaged(u64) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |item| {
            if (item.kind != .file or !std.mem.endsWith(u8, item.name, ".log")) continue;
            const number = std.fmt.parseInt(u64, item.name[0 .. item.name.len - 4], 10) catch continue;
            if (number >= version.log_number or (version.prev_log_number != 0 and number == version.prev_log_number)) try logs.append(scratch, number);
        }
        std.mem.sort(u64, logs.items, {}, std.sort.asc(u64));
        var memos: std.ArrayListUnmanaged(Memo) = .empty;
        for (logs.items) |number| {
            var name: [32]u8 = undefined;
            const bytes = try dir.readFileAlloc(io, try std.fmt.bufPrint(&name, "{d:0>6}.log", .{number}), scratch, .limited(1 << 32));
            var reader: LogReader = .{ .bytes = bytes };
            while (try reader.next(scratch)) |record| try applyBatch(scratch, record, &memos);
        }
        std.mem.sort(Memo, memos.items, {}, Memo.lessThan);

        // Level 0 tables may overlap; deeper levels chain.
        var levels: [7]std.ArrayListUnmanaged(FileMeta) = @splat(.empty);
        for (version.files.values()) |meta| {
            if (meta.level >= levels.len) return error.Corrupt;
            try levels[meta.level].append(scratch, meta);
        }
        var sources: std.ArrayListUnmanaged(Source) = .empty;
        try sources.append(scratch, .{ .memtable = memos.items });
        for (levels[0].items) |meta| try sources.append(scratch, .{ .tables = try scratch.dupe(u64, &.{meta.number}) });
        for (levels[1..]) |level| {
            std.mem.sort(FileMeta, level.items, {}, struct {
                fn lessThan(_: void, a: FileMeta, b: FileMeta) bool {
                    return std.mem.order(u8, a.smallest, b.smallest) == .lt;
                }
            }.lessThan);
            const numbers = try scratch.alloc(u64, level.items.len);
            for (level.items, numbers) |meta, *n| n.* = meta.number;
            if (numbers.len != 0) try sources.append(scratch, .{ .tables = numbers });
        }
        return .{ .allocator = allocator, .io = io, .dir = dir, .arena = arena, .sources = sources.items };
    }

    pub fn deinit(self: *Reader) void {
        for (self.sources) |*source| if (source.table) |*table| table.deinit(self.allocator);
        self.last_key.deinit(self.allocator);
        self.value.deinit(self.allocator);
        self.arena.deinit();
    }

    fn applyBatch(allocator: std.mem.Allocator, record: []const u8, memos: *std.ArrayListUnmanaged(Memo)) !void {
        if (record.len < 12) return error.Corrupt;
        var sequence = std.mem.readInt(u64, record[0..8], .little);
        const count = std.mem.readInt(u32, record[8..12], .little);
        var at: usize = 12;
        for (0..count) |_| {
            if (at >= record.len) return error.Corrupt;
            const kind = record[at];
            at += 1;
            const key = try allocator.dupe(u8, try slice(record, &at));
            const value: ?[]const u8 = switch (kind) {
                1 => try allocator.dupe(u8, try slice(record, &at)),
                0 => null,
                else => return error.Corrupt,
            };
            try memos.append(allocator, .{ .key = key, .sequence = sequence, .value = value });
            sequence += 1;
        }
    }

    fn advance(self: *Reader, source: *Source) !void {
        if (source.tables.len == 0) {
            if (source.memo_at == source.memtable.len) {
                source.done = true;
                return;
            }
            const memo = source.memtable[source.memo_at];
            source.memo_at += 1;
            source.key = memo.key;
            source.sequence = memo.sequence;
            source.value = memo.value;
            return;
        }
        while (true) {
            if (source.table == null) {
                if (source.position == source.tables.len) {
                    source.done = true;
                    return;
                }
                var name: [32]u8 = undefined;
                const number = source.tables[source.position];
                source.position += 1;
                const handle = self.dir.openFile(self.io, try std.fmt.bufPrint(&name, "{d:0>6}.ldb", .{number}), .{}) catch |err| switch (err) {
                    error.FileNotFound => try self.dir.openFile(self.io, try std.fmt.bufPrint(&name, "{d:0>6}.sst", .{number}), .{}),
                    else => return err,
                };
                source.table = try TableIterator.open(self.allocator, .{ .handle = handle, .io = self.io });
            }
            const table = &source.table.?;
            if (try table.next(self.allocator)) {
                const key = table.key.items;
                const tag = std.mem.readInt(u64, key[key.len - 8 ..][0..8], .little);
                source.key = key[0 .. key.len - 8];
                source.sequence = tag >> 8;
                source.value = switch (@as(u8, @truncate(tag))) {
                    1 => table.value,
                    0 => null,
                    else => return error.Corrupt,
                };
                return;
            }
            table.deinit(self.allocator);
            source.table = null;
        }
    }

    /// Valid until the next call.
    pub fn next(self: *Reader) !?struct { []const u8, []const u8 } {
        if (!self.started) {
            self.started = true;
            for (self.sources) |*source| try self.advance(source);
        }
        while (true) {
            var best: ?*Source = null;
            for (self.sources) |*source| {
                if (source.done) continue;
                const current = best orelse {
                    best = source;
                    continue;
                };
                switch (std.mem.order(u8, source.key, current.key)) {
                    .lt => best = source,
                    .eq => if (source.sequence > current.sequence) {
                        best = source;
                    },
                    .gt => {},
                }
            }
            const winner = best orelse return null;
            self.last_key.clearRetainingCapacity();
            try self.last_key.appendSlice(self.allocator, winner.key);
            const live = winner.value != null;
            self.value.clearRetainingCapacity();
            if (winner.value) |v| try self.value.appendSlice(self.allocator, v);
            for (self.sources) |*source| {
                while (!source.done and std.mem.eql(u8, source.key, self.last_key.items)) try self.advance(source);
            }
            if (live) return .{ self.last_key.items, self.value.items };
        }
    }
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    compression: Compression,
    file_number: u64 = 2,
    table: ?File = null,
    table_offset: u64 = 0,
    block: std.ArrayListUnmanaged(u8) = .empty,
    restarts: std.ArrayListUnmanaged(u32) = .empty,
    index: std.ArrayListUnmanaged(u8) = .empty,
    index_restarts: std.ArrayListUnmanaged(u32) = .empty,
    last_key: std.ArrayListUnmanaged(u8) = .empty,
    smallest: std.ArrayListUnmanaged(u8) = .empty,
    block_entries: usize = 0,
    compressed: std.ArrayListUnmanaged(u8) = .empty,
    edit: std.ArrayListUnmanaged(u8) = .empty,
    window: []u8 = &.{},
    pending_handle: ?[2]u64 = null,
    pending_key: std.ArrayListUnmanaged(u8) = .empty,
    count: u64 = 0,

    const target_block = 64 * 1024;
    const target_table = 2 * 1024 * 1024;
    const restart_interval = 16;
    const sequence = 1;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, compression: Compression) !Writer {
        var self: Writer = .{ .allocator = allocator, .io = io, .dir = dir, .compression = compression };
        self.window = try allocator.alloc(u8, flate.max_window_len);
        try self.edit.append(allocator, 1);
        try putSlice(&self.edit, allocator, "leveldb.BytewiseComparator");
        return self;
    }

    pub fn deinit(self: *Writer) void {
        if (self.table) |file| file.handle.close(self.io);
        inline for (.{ "block", "restarts", "index", "index_restarts", "last_key", "smallest", "compressed", "edit", "pending_key" }) |field| @field(self, field).deinit(self.allocator);
        self.allocator.free(self.window);
    }

    pub fn add(self: *Writer, key: []const u8, value: []const u8) !void {
        if (self.count != 0 and std.mem.order(u8, key, self.last_key.items[0 .. self.last_key.items.len - 8]) != .gt) return error.KeyOrder;
        if (self.table == null) try self.startTable();
        if (self.pending_handle) |handle| try self.addIndex(handle);
        var internal: [8]u8 = undefined;
        std.mem.writeInt(u64, &internal, sequence << 8 | 1, .little);

        var shared: usize = 0;
        if (self.block_entries % restart_interval == 0) {
            try self.restarts.append(self.allocator, @intCast(self.block.items.len));
        } else {
            const previous = self.last_key.items;
            const limit = @min(previous.len, key.len + 8);
            while (shared < limit and previous[shared] == (if (shared < key.len) key[shared] else internal[shared - key.len])) shared += 1;
        }
        const full_len = key.len + 8;
        try putVarint(&self.block, self.allocator, shared);
        try putVarint(&self.block, self.allocator, full_len - shared);
        try putVarint(&self.block, self.allocator, value.len);
        if (shared < key.len) {
            try self.block.appendSlice(self.allocator, key[shared..]);
            try self.block.appendSlice(self.allocator, &internal);
        } else try self.block.appendSlice(self.allocator, internal[shared - key.len ..]);
        try self.block.appendSlice(self.allocator, value);
        self.block_entries += 1;

        self.last_key.clearRetainingCapacity();
        try self.last_key.appendSlice(self.allocator, key);
        try self.last_key.appendSlice(self.allocator, &internal);
        if (self.smallest.items.len == 0) try self.smallest.appendSlice(self.allocator, self.last_key.items);
        self.count += 1;

        if (self.block.items.len >= target_block) try self.flushBlock();
        if (self.table_offset >= target_table) try self.finishTable();
    }

    fn startTable(self: *Writer) !void {
        self.file_number += 1;
        var name: [32]u8 = undefined;
        const handle = try self.dir.createFile(self.io, try std.fmt.bufPrint(&name, "{d:0>6}.ldb", .{self.file_number}), .{ .exclusive = true });
        self.table = .{ .handle = handle, .io = self.io };
        self.table_offset = 0;
        self.smallest.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        self.index_restarts.clearRetainingCapacity();
    }

    fn addIndex(self: *Writer, handle: [2]u64) !void {
        try self.index_restarts.append(self.allocator, @intCast(self.index.items.len));
        var value: std.ArrayListUnmanaged(u8) = .empty;
        defer value.deinit(self.allocator);
        try putVarint(&value, self.allocator, handle[0]);
        try putVarint(&value, self.allocator, handle[1]);
        try putVarint(&self.index, self.allocator, 0);
        try putVarint(&self.index, self.allocator, self.pending_key.items.len);
        try putVarint(&self.index, self.allocator, value.items.len);
        try self.index.appendSlice(self.allocator, self.pending_key.items);
        try self.index.appendSlice(self.allocator, value.items);
        self.pending_handle = null;
    }

    fn finishBlock(list: *std.ArrayListUnmanaged(u8), restarts: *std.ArrayListUnmanaged(u32), allocator: std.mem.Allocator) !void {
        if (restarts.items.len == 0) try restarts.append(allocator, 0);
        for (restarts.items) |r| try list.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(u32, r)));
        try list.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(u32, @intCast(restarts.items.len))));
    }

    fn writeBlock(self: *Writer, contents: []const u8, allow_compression: bool) ![2]u64 {
        const file = self.table.?;
        var kind: u8 = 0;
        var data = contents;
        if (allow_compression and self.compression != .none) {
            self.compressed.clearRetainingCapacity();
            try self.compressed.ensureTotalCapacity(self.allocator, contents.len + 1024);
            var out: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.compressed);
            var deflate = try flate.Compress.init(&out.writer, self.window, if (self.compression == .zlib) .zlib else .raw, .level_6);
            try deflate.writer.writeAll(contents);
            try deflate.finish();
            self.compressed = out.toArrayList();
            // LevelDB's rule: keep it raw unless it saves an eighth.
            if (self.compressed.items.len < contents.len - contents.len / 8) {
                kind = @intFromEnum(self.compression);
                data = self.compressed.items;
            }
        }
        const offset = self.table_offset;
        try file.writeAll(data, offset);
        var trailer: [5]u8 = undefined;
        trailer[0] = kind;
        std.mem.writeInt(u32, trailer[1..5], mask(~crc.update(crc.update(0xffff_ffff, data), trailer[0..1])), .little);
        try file.writeAll(&trailer, offset + data.len);
        self.table_offset += data.len + 5;
        return .{ offset, data.len };
    }

    fn flushBlock(self: *Writer) !void {
        if (self.block_entries == 0) return;
        try finishBlock(&self.block, &self.restarts, self.allocator);
        const handle = try self.writeBlock(self.block.items, true);
        self.block.clearRetainingCapacity();
        self.restarts.clearRetainingCapacity();
        self.block_entries = 0;
        self.pending_key.clearRetainingCapacity();
        try self.pending_key.appendSlice(self.allocator, self.last_key.items);
        self.pending_handle = handle;
    }

    fn finishTable(self: *Writer) !void {
        try self.flushBlock();
        if (self.pending_handle) |handle| try self.addIndex(handle);
        var meta: std.ArrayListUnmanaged(u8) = .empty;
        defer meta.deinit(self.allocator);
        var no_restarts: std.ArrayListUnmanaged(u32) = .empty;
        defer no_restarts.deinit(self.allocator);
        try finishBlock(&meta, &no_restarts, self.allocator);
        const meta_handle = try self.writeBlock(meta.items, false);
        try finishBlock(&self.index, &self.index_restarts, self.allocator);
        const index_handle = try self.writeBlock(self.index.items, false);

        var footer: std.ArrayListUnmanaged(u8) = .empty;
        defer footer.deinit(self.allocator);
        for ([_]u64{ meta_handle[0], meta_handle[1], index_handle[0], index_handle[1] }) |v| try putVarint(&footer, self.allocator, v);
        try footer.appendNTimes(self.allocator, 0, 40 - footer.items.len);
        try footer.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(u64, table_magic)));
        const file = self.table.?;
        try file.writeAll(footer.items, self.table_offset);
        self.table_offset += footer_len;
        try file.sync();
        file.handle.close(self.io);
        self.table = null;

        try putVarint(&self.edit, self.allocator, 7);
        try putVarint(&self.edit, self.allocator, 6);
        try putVarint(&self.edit, self.allocator, self.file_number);
        try putVarint(&self.edit, self.allocator, self.table_offset);
        try putSlice(&self.edit, self.allocator, self.smallest.items);
        try putSlice(&self.edit, self.allocator, self.last_key.items);
    }

    pub fn finish(self: *Writer) !void {
        if (self.table != null) try self.finishTable();
        try putVarint(&self.edit, self.allocator, 2);
        try putVarint(&self.edit, self.allocator, 0);
        try putVarint(&self.edit, self.allocator, 3);
        try putVarint(&self.edit, self.allocator, self.file_number + 1);
        try putVarint(&self.edit, self.allocator, 4);
        try putVarint(&self.edit, self.allocator, sequence);

        const handle = try self.dir.createFile(self.io, "MANIFEST-000002", .{ .exclusive = true });
        defer handle.close(self.io);
        var log: LogWriter = .{ .file = .{ .handle = handle, .io = self.io } };
        try log.add(self.edit.items);
        try log.file.sync();
        try self.dir.writeFile(self.io, .{ .sub_path = "CURRENT", .data = "MANIFEST-000002\n" });
    }
};

test "log records span blocks and survive a round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const handle = try tmp.dir.createFile(io, "log", .{ .read = true });
    defer handle.close(io);
    var writer: LogWriter = .{ .file = .{ .handle = handle, .io = io } };
    var big: [70000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i * 7);
    try writer.add("small");
    try writer.add(&big);
    try writer.add("after");
    const bytes = try tmp.dir.readFileAlloc(io, "log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    var reader: LogReader = .{ .bytes = bytes };
    defer reader.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("small", (try reader.next(std.testing.allocator)).?);
    try std.testing.expectEqualSlices(u8, &big, (try reader.next(std.testing.allocator)).?);
    try std.testing.expectEqualStrings("after", (try reader.next(std.testing.allocator)).?);
    try std.testing.expectEqual(null, try reader.next(std.testing.allocator));
}
