const std = @import("std");
const db = @import("zigritedb");
const testing = std.testing;
const io = testing.io;

const Work = struct {
    started: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    completed: usize = 0,

    fn run(self: *Work, region: db.Region) !void {
        if (region.x == 0) {
            self.started.set(io);
            self.release.waitUncancelable(io);
        }
        self.completed += 1;
        if (region.x == 5) return error.CompactionFailed;
    }
};

test "maintenance bounds queued work and drains after a failure" {
    var work: Work = .{};
    var queue: db.maintenance.Queue(Work, Work.run) = .{ .io = io, .context = &work };
    defer queue.close() catch {};
    defer work.release.set(io);
    try queue.submit(.{ .dimension = 0, .x = 0, .z = 0 });
    work.started.waitUncancelable(io);
    try testing.expectError(error.AlreadyQueued, queue.submit(.{ .dimension = 0, .x = 0, .z = 0 }));
    for (1..17) |x| try queue.submit(.{ .dimension = 0, .x = @intCast(x), .z = 0 });
    try testing.expectError(error.QueueFull, queue.submit(.{ .dimension = 0, .x = 17, .z = 0 }));
    work.release.set(io);
    try testing.expectError(error.CompactionFailed, queue.wait());
    try testing.expectEqual(@as(usize, 17), work.completed);
    try queue.wait();
    try queue.submit(.{ .dimension = 0, .x = 18, .z = 0 });
    try queue.close();
    try testing.expectEqual(@as(usize, 18), work.completed);
    try testing.expectError(error.Closed, queue.submit(.{ .dimension = 0, .x = 19, .z = 0 }));
}
