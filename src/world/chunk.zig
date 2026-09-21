const World = @import("world.zig").World;
const store_module = @import("../shard/store.zig");
const Component = @import("../format/key.zig").Component;

pub const ChunkComponent = struct {
    component: Component,
    subchunk_y: i32 = 0,
    output: []u8,
};

/// Thin wrapper over `World.getMany`: just builds one `Key` per component.
pub fn getChunkComponents(
    world: *World,
    dimension: i32,
    chunk_x: i32,
    chunk_z: i32,
    components: []const ChunkComponent,
    results: []store_module.ReadResult,
) !void {
    if (components.len > store_module.max_batch_keys) return error.TooManyKeys;

    var requests: [store_module.max_batch_keys]store_module.ReadRequest = undefined;
    for (components, 0..) |component, i| {
        requests[i] = .{
            .key = .{
                .dimension = dimension,
                .chunk_x = chunk_x,
                .chunk_z = chunk_z,
                .component = component.component,
                .subchunk_y = component.subchunk_y,
            },
            .output = component.output,
        };
    }

    try world.getMany(requests[0..components.len], results);
}
