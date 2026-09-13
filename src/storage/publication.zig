pub fn Publisher(comptime Backend: type) type {
    return struct {
        backend: Backend,

        pub fn publish(self: *@This(), bytes: []const u8) !void {
            try self.backend.writeTemporary(bytes);
            try self.backend.syncTemporary();
            try self.backend.replaceManifest();
            try self.backend.syncDirectory();
        }
    };
}
