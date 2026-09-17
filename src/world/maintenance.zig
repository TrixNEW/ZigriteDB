const std = @import("std");

const Region = @import("../format/key.zig").Region;

pub fn Queue(comptime Context: type, comptime run: fn (*Context, Region) anyerror!void) type {
    return struct {
        io: std.Io,
        context: *Context,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        regions: [16]Region = undefined,
        head: usize = 0,
        count: usize = 0,
        active: ?Region = null,
        failure: ?anyerror = null,
        stopping: bool = false,

        const Self = @This();

        /// Keep the queue and context at stable addresses until close returns.
        pub fn submit(self: *Self, region: Region) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping) return error.Closed;
            if (self.count == self.regions.len) return error.QueueFull;
            if (self.active) |active| {
                if (std.meta.eql(active, region)) return error.AlreadyQueued;
            }
            for (0..self.count) |i| {
                if (std.meta.eql(self.regions[(self.head + i) % self.regions.len], region)) return error.AlreadyQueued;
            }
            if (self.thread == null) self.thread = try std.Thread.spawn(.{}, work, .{self});
            self.regions[(self.head + self.count) % self.regions.len] = region;
            self.count += 1;
            self.changed.broadcast(self.io);
        }

        /// Waits for queued work and reports the first failure since the last wait.
        pub fn wait(self: *Self) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.count != 0 or self.active != null) try self.changed.wait(self.io, &self.mutex);
            const failure = self.failure;
            self.failure = null;
            if (failure) |err| return err;
        }

        /// Finish submit and wait calls before closing.
        pub fn close(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
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
                const region = self.regions[self.head];
                self.head = (self.head + 1) % self.regions.len;
                self.count -= 1;
                self.active = region;
                self.mutex.unlock(self.io);
                const result = run(self.context, region);
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
