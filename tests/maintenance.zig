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

test "a non-draining queue drops pending work on close" {
    var work: Work = .{};
    var queue: db.maintenance.WorkQueue(Work, db.Region, 4, false, Work.run) = .{ .io = io, .context = &work };
    try queue.submit(.{ .dimension = 0, .x = 0, .z = 0 });
    work.started.waitUncancelable(io);
    for (1..5) |x| try queue.submit(.{ .dimension = 0, .x = @intCast(x), .z = 0 });
    try testing.expectError(error.QueueFull, queue.submit(.{ .dimension = 0, .x = 9, .z = 0 }));

    const closer = try std.Thread.spawn(.{}, closeQueue, .{&queue});
    while (true) {
        queue.mutex.lockUncancelable(io);
        const stopping = queue.stopping;
        queue.mutex.unlock(io);
        if (stopping) break;
        std.Thread.yield() catch {};
    }
    work.release.set(io);
    closer.join();
    try testing.expectEqual(@as(usize, 1), work.completed);
}

fn closeQueue(queue: anytype) void {
    queue.close() catch {};
}

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
