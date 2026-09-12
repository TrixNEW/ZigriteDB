const std = @import("std");
const entry = @import("../format/entry.zig");
const record = @import("../format/record.zig");
const Region = @import("../format/key.zig").Region;
const Crc32c = std.hash.crc.Crc32Iscsi;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const commit_len = 80;
pub const max_records = 4096;
pub const max_bytes = 64 * 1024 * 1024;

pub const Error = entry.Error || error{
    EmptyBatch,
    BatchTooLarge,
    BatchIdMismatch,
    RegionMismatch,
    InvalidCommit,
    IncompleteCommit,
    BatchMismatch,
};

const Summary = struct {
    batch_id: u64,
    count: u32,
    digest: [32]u8,
};

/// Builds a commit marker for complete records from one batch and region.
pub fn seal(records: []const u8) Error![commit_len]u8 {
    const summary = try summarize(records);
    var bytes: [commit_len]u8 = undefined;
    const header = try (record.Header{ .kind = .commit, .batch_id = summary.batch_id }).encode();
    @memcpy(bytes[0..32], &header);
    std.mem.writeInt(u32, bytes[32..36], summary.count, .little);
    std.mem.writeInt(u64, bytes[36..44], records.len, .little);
    @memcpy(bytes[44..76], &summary.digest);
    std.mem.writeInt(u32, bytes[76..80], Crc32c.hash(bytes[0..76]), .little);
    return bytes;
}

/// Checks batch contents, not disk durability. Keep both buffers unchanged during the call.
pub fn verify(records: []const u8, commit: []const u8) Error!void {
    if (commit.len < commit_len) return error.IncompleteCommit;
    if (commit.len != commit_len) return error.InvalidCommit;
    const header = try record.Header.decode(commit);
    if (header.kind != .commit) return error.InvalidCommit;
    if (std.mem.readInt(u32, commit[76..80], .little) != Crc32c.hash(commit[0..76]))
        return error.ChecksumMismatch;

    const count = std.mem.readInt(u32, commit[32..36], .little);
    const byte_len = std.mem.readInt(u64, commit[36..44], .little);
    if (count == 0 or count > max_records or byte_len == 0 or byte_len > max_bytes)
        return error.InvalidCommit;
    if (byte_len != records.len) return error.BatchMismatch;

    const summary = try summarize(records);
    if (header.batch_id != summary.batch_id or count != summary.count or
        !std.mem.eql(u8, commit[44..76], &summary.digest))
        return error.BatchMismatch;
}

fn summarize(records: []const u8) Error!Summary {
    if (records.len == 0) return error.EmptyBatch;
    if (records.len > max_bytes) return error.BatchTooLarge;

    var offset: usize = 0;
    var count: u32 = 0;
    var batch_id: u64 = 0;
    var region: Region = undefined;
    while (offset < records.len) {
        if (count == max_records) return error.BatchTooLarge;
        const decoded = try entry.decode(records[offset..]);
        const current = decoded.entry.key.region();
        if (count == 0) {
            batch_id = decoded.entry.header.batch_id;
            region = current;
        } else {
            if (decoded.entry.header.batch_id != batch_id) return error.BatchIdMismatch;
            if (current.dimension != region.dimension or current.x != region.x or current.z != region.z)
                return error.RegionMismatch;
        }
        offset = std.math.add(usize, offset, decoded.consumed) catch return error.BatchTooLarge;
        count += 1;
    }

    var digest: [32]u8 = undefined;
    // Hash full records so missing, repeated, or reordered records change the digest.
    Sha256.hash(records, &digest, .{});
    return .{ .batch_id = batch_id, .count = count, .digest = digest };
}
