const vk = @import("vulkan");
const Buffer = @import("buffer.zig");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const za = @import("zalgebra");
const Vec3 = za.Vec3;

pub const Vertex = struct {
    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: Vec3,
    color: Vec3,
};

pub const Mesh = struct {
    vertex_buffer: Buffer,
    index_buffer: Buffer,
    index_count: u32,

    pub fn initCube(gc: *GraphicsContext, command_pool: vk.CommandPool) !Mesh {
        const vertices = [_]Vertex{
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .color = Vec3.new(1, 0, 0) },
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .color = Vec3.new(0, 1, 0) },
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .color = Vec3.new(0, 0, 1) },
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .color = Vec3.new(1, 1, 0) },

            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .color = Vec3.new(1, 0, 1) },
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .color = Vec3.new(0, 1, 1) },
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .color = Vec3.new(1, 1, 1) },
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .color = Vec3.new(0, 0, 0) },
        };

        const indices = [_]u32{
            0, 1, 2, 2, 3, 0,
            4, 6, 5, 6, 4, 7,
            4, 0, 3, 3, 7, 4,
            1, 5, 6, 6, 2, 1,
            3, 2, 6, 6, 7, 3,
            4, 5, 1, 1, 0, 4,
        };

        // reuse your staging logic (inline for now)
        const vertex_size = @sizeOf(@TypeOf(vertices));
        const index_size = @sizeOf(@TypeOf(indices));

        var staging = try Buffer.init(
            gc,
            vertex_size + index_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging.deinit(gc);

        try staging.mapWrite(gc, Vertex, vertices[0..], 0);
        try staging.mapWrite(gc, u32, indices[0..], vertex_size);

        const vertex_buffer = try Buffer.init(
            gc,
            vertex_size,
            .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
            .{ .device_local_bit = true },
        );

        const index_buffer = try Buffer.init(
            gc,
            index_size,
            .{ .transfer_dst_bit = true, .index_buffer_bit = true },
            .{ .device_local_bit = true },
        );

        try staging.copyTo(gc, command_pool, vertex_buffer, 0);
        try staging.copyTo(gc, command_pool, index_buffer, vertex_size);

        return Mesh{
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .index_count = indices.len,
        };
    }

    pub fn draw(self: *Mesh, gc: *GraphicsContext, cmdbuf: vk.CommandBuffer) void {
        const offsets = [_]vk.DeviceSize{0};

        gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&self.vertex_buffer.buffer), &offsets);
        gc.dev.cmdBindIndexBuffer(cmdbuf, self.index_buffer.buffer, 0, .uint32);
        gc.dev.cmdDrawIndexed(cmdbuf, self.index_count, 1, 0, 0, 0);
    }

    pub fn deinit(self: *Mesh, gc: *GraphicsContext) void {
        self.vertex_buffer.deinit(gc);
        self.index_buffer.deinit(gc);
    }
};
