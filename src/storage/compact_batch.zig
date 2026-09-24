const commit = @import("../batch/commit.zig");
const entry = @import("../format/entry.zig");
const index_module = @import("../index/index.zig");
const Batch = @import("../recovery/scan.zig").Batch;

pub fn compactBatch(index: *const index_module.Index, position: usize, batch: Batch, output: []u8) ![]const u8 {
    const start = batch.end_offset - commit.commit_len - batch.records.len;
    var read: usize = 0;
    var written: usize = 0;
    while (read < batch.records.len) {
        const decoded = try entry.decode(batch.records[read..]);
        const location = try index.get(decoded.entry.key);
        const keep = batch.id == index.last_batch_id or if (location) |live|
            live.segment == position and live.offset == start + read
        else
            false;
        if (keep) {
            @memcpy(output[written..][0..decoded.consumed], batch.records[read..][0..decoded.consumed]);
            written += decoded.consumed;
        }
        read += decoded.consumed;
    }
    if (written == 0) return output[0..0];
    const marker = try commit.seal(output[0..written]);
    @memcpy(output[written..][0..commit.commit_len], &marker);
    return output[0 .. written + commit.commit_len];
}
