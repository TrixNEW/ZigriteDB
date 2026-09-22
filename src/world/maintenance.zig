const std = @import("std");

const Region = @import("../format/key.zig").Region;

pub fn Queue(comptime Context: type, comptime run: fn (*Context, Region) anyerror!void) type {
    return WorkQueue(Context, Region, 16, true, run);
}

/// Bounded background queue with optional draining on close.
pub fn WorkQueue(
    comptime Context: type,
    comptime Item: type,
    comptime capacity: usize,
    comptime drain_on_close: bool,
    comptime run: fn (*Context, Item) anyerror!void,
) type {
    return struct {
        io: std.Io,
        context: *Context,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        items: [capacity]Item = undefined,
        head: usize = 0,
        count: usize = 0,
        active: ?Item = null,
        failure: ?anyerror = null,
        stopping: bool = false,

        const Self = @This();

        pub fn submit(self: *Self, item: Item) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping) return error.Closed;
            if (self.count == self.items.len) return error.QueueFull;
            if (self.active) |active| {
                if (std.meta.eql(active, item)) return error.AlreadyQueued;
            }
            for (0..self.count) |i| {
                if (std.meta.eql(self.items[(self.head + i) % self.items.len], item)) return error.AlreadyQueued;
            }
            if (self.thread == null) self.thread = try std.Thread.spawn(.{}, work, .{self});
            self.items[(self.head + self.count) % self.items.len] = item;
            self.count += 1;
            self.changed.broadcast(self.io);
        }

        pub fn wait(self: *Self) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.count != 0 or self.active != null) try self.changed.wait(self.io, &self.mutex);
            const failure = self.failure;
            self.failure = null;
            if (failure) |err| return err;
        }

        pub fn close(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            if (!drain_on_close) self.count = 0;
            self.changed.broadcast(self.io);
            const thread = self.thread;
            self.mutex.unlock(self.io);
            if (thread) |worker| worker.join();
            self.thread = null;
            if (self.failure) |err| {
                self.failure = null;
                return err;
            }
        }

        fn work(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (true) {
                while (self.count == 0 and !self.stopping) self.changed.waitUncancelable(self.io, &self.mutex);
                if (self.count == 0) return;
                const item = self.items[self.head];
                self.head = (self.head + 1) % self.items.len;
                self.count -= 1;
                self.active = item;
                self.mutex.unlock(self.io);
                const result = run(self.context, item);
                self.mutex.lockUncancelable(self.io);
                result catch |err| {
                    if (self.failure == null) self.failure = err;
                };
                self.active = null;
                self.changed.broadcast(self.io);
            }
        }
    };
}
