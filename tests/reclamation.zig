const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;

const Backend = struct {
    present: [4]bool = .{ true, true, true, false },
    fail_id: u64 = 0,
    syncs: usize = 0,
    fail_sync: usize = 0,

    pub fn syncEntries(self: *Backend) !void {
        self.syncs += 1;
        if (self.syncs == self.fail_sync) return error.InputOutput;
    }

    pub fn removeSegment(self: *Backend, generation: u64, id: u64) !void {
        try testing.expectEqual(@as(u64, 1), generation);
        try testing.expect(self.syncs > 0);
        if (id == self.fail_id) return error.AccessDenied;
        if (!self.present[id - 1]) return error.FileNotFound;
        self.present[id - 1] = false;
    }
};

test "cleanup validates the full request before removing anything" {
    var backend: Backend = .{};
    try testing.expectEqual(error.InvalidGeneration, db.reclamation.reclaim(&backend, 2, 2, &.{1}).failure.?);
    try testing.expectEqual(error.InvalidGeneration, db.reclamation.reclaim(&backend, 2, 3, &.{1}).failure.?);
    try testing.expectEqual(error.InvalidSegmentOrder, db.reclamation.reclaim(&backend, 2, 1, &.{ 2, 1 }).failure.?);
    try testing.expectEqual(@as(usize, 0), backend.syncs);
    try testing.expect(backend.present[0] and backend.present[1]);
}

test "cleanup retries failed removals and tolerates missing files" {
    var backend: Backend = .{ .fail_id = 2 };
    const partial = db.reclamation.reclaim(&backend, 2, 1, &.{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(usize, 2), partial.removed_segments);
    try testing.expectEqual(@as(usize, 1), partial.retained_segments);
    try testing.expectEqual(error.AccessDenied, partial.failure.?);
    try testing.expect(partial.synced);
    backend.fail_id = 0;
    const retry = db.reclamation.reclaim(&backend, 2, 1, &.{ 1, 2, 3, 4 });
    try testing.expectEqual(@as(usize, 1), retry.removed_segments);
    try testing.expectEqual(@as(usize, 0), retry.retained_segments);
    try testing.expect(retry.synced and retry.failure == null);
}

test "cleanup reports sync failures before and after removal" {
    var backend: Backend = .{ .fail_sync = 1 };
    const before = db.reclamation.reclaim(&backend, 2, 1, &.{1});
    try testing.expect(!before.synced and backend.present[0]);
    try testing.expectEqual(error.InputOutput, before.failure.?);
    backend.syncs = 0;
    backend.fail_sync = 2;
    const after = db.reclamation.reclaim(&backend, 2, 1, &.{1});
    try testing.expect(!after.synced and !backend.present[0]);
    try testing.expectEqual(error.InputOutput, after.failure.?);
    backend.fail_sync = 0;
    const retry = db.reclamation.reclaim(&backend, 2, 1, &.{1});
    try testing.expect(retry.synced and retry.failure == null);
}
