pub const Result = struct {
    removed_segments: usize = 0,
    retained_segments: usize = 0,
    synced: bool = false,
    failure: ?anyerror = null,
};

/// The backend must hold the store lock and its published generation must be current.
pub fn reclaim(backend: anytype, current: u64, generation: u64, ids: []const u64) Result {
    var result: Result = .{ .retained_segments = ids.len };
    if (generation == 0 or generation >= current) {
        result.failure = error.InvalidGeneration;
        return result;
    }
    var previous: u64 = 0;
    for (ids) |id| {
        if (id <= previous) {
            result.failure = error.InvalidSegmentOrder;
            return result;
        }
        previous = id;
    }
    backend.syncEntries() catch |err| {
        result.failure = err;
        return result;
    };
    for (ids) |id| {
        backend.removeSegment(generation, id) catch |err| {
            if (err == error.FileNotFound) {
                result.retained_segments -= 1;
            } else if (result.failure == null) {
                result.failure = err;
            }
            continue;
        };
        result.removed_segments += 1;
        result.retained_segments -= 1;
    }
    backend.syncEntries() catch |err| {
        if (result.failure == null) result.failure = err;
        return result;
    };
    result.synced = true;
    return result;
}
