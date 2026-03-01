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

const std = @import("std");

pub const Mesh = struct {
    vertex_buffer: Buffer,
    index_buffer: Buffer,
    index_count: u32,

    pub fn initCube(gc: *GraphicsContext, command_pool: vk.CommandPool) !Mesh {
        const vertices = [_]Vertex{
            // Front face (Red) - CCW: Bottom-Left, Bottom-Right, Top-Right, Top-Left
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .color = Vec3.new(1, 0, 0) }, // 0
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .color = Vec3.new(1, 0, 0) }, // 1
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .color = Vec3.new(1, 0, 0) }, // 2
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .color = Vec3.new(1, 0, 0) }, // 3

            // Back face (Green) - CCW: Bottom-Right, Bottom-Left, Top-Left, Top-Right
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .color = Vec3.new(0, 1, 0) }, // 4
            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .color = Vec3.new(0, 1, 0) }, // 5
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .color = Vec3.new(0, 1, 0) }, // 6
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .color = Vec3.new(0, 1, 0) }, // 7

            // Top face (Blue) - CCW
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .color = Vec3.new(0, 0, 1) }, // 8
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .color = Vec3.new(0, 0, 1) }, // 9
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .color = Vec3.new(0, 0, 1) }, // 10
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .color = Vec3.new(0, 0, 1) }, // 11

            // Bottom face (Yellow)
            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .color = Vec3.new(1, 1, 0) }, // 12
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .color = Vec3.new(1, 1, 0) }, // 13
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .color = Vec3.new(1, 1, 0) }, // 14
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .color = Vec3.new(1, 1, 0) }, // 15

            // Right face (Magenta)
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .color = Vec3.new(1, 0, 1) }, // 16
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .color = Vec3.new(1, 0, 1) }, // 17
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .color = Vec3.new(1, 0, 1) }, // 18
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .color = Vec3.new(1, 0, 1) }, // 19

            // Left face (Cyan)
            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .color = Vec3.new(0, 1, 1) }, // 20
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .color = Vec3.new(0, 1, 1) }, // 21
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .color = Vec3.new(0, 1, 1) }, // 22
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .color = Vec3.new(0, 1, 1) }, // 23
        };

        const indices = [_]u32{
            0, 1, 2, 2, 3, 0, // Front
            4, 5, 6, 6, 7, 4, // Back
            8, 9, 10, 10, 11, 8, // Top
            12, 13, 14, 14, 15, 12, // Bottom
            16, 17, 18, 18, 19, 16, // Right
            20, 21, 22, 22, 23, 20, // Left
        };

        return .init(gc, command_pool, &vertices, &indices);
    }

    pub fn initTorus(gc: *GraphicsContext, command_pool: vk.CommandPool) !Mesh {
        const main_segments = 32;
        const tube_segments = 32;
        const main_radius = 0.7;
        const tube_radius = 0.3;

        var vertices = std.ArrayList(Vertex).empty;
        defer vertices.deinit(gc.allocator);
        var indices = std.ArrayList(u32).empty;
        defer indices.deinit(gc.allocator);

        for (0..main_segments + 1) |i| {
            const u = @as(f32, @floatFromInt(i)) / main_segments * 2.0 * std.math.pi;

            for (0..tube_segments + 1) |j| {
                const v = @as(f32, @floatFromInt(j)) / tube_segments * 2.0 * std.math.pi;

                // Parametric equations for a torus
                const x = (main_radius + tube_radius * std.math.cos(v)) * std.math.cos(u);
                const y = (main_radius + tube_radius * std.math.cos(v)) * std.math.sin(u);
                const z = tube_radius * std.math.sin(v);

                // Create a color based on the position for a cool gradient
                const color = Vec3.new(
                    std.math.cos(u) * 0.5 + 0.5,
                    std.math.sin(v) * 0.5 + 0.5,
                    0.5,
                );

                try vertices.append(gc.allocator, .{
                    .pos = Vec3.new(x, y, z),
                    .color = color,
                });
            }
        }

        for (0..main_segments) |i| {
            for (0..tube_segments) |j| {
                const first = @as(u32, @intCast(i * (tube_segments + 1) + j));
                const second = first + tube_segments + 1;

                // First triangle
                try indices.append(gc.allocator, first);
                try indices.append(gc.allocator, second);
                try indices.append(gc.allocator, first + 1);

                // Second triangle
                try indices.append(gc.allocator, second);
                try indices.append(gc.allocator, second + 1);
                try indices.append(gc.allocator, first + 1);
            }
        }

        return .init(gc, command_pool, vertices.items, indices.items);
    }

    pub fn init(gc: *GraphicsContext, command_pool: vk.CommandPool, vertices: []const Vertex, indices: []const u32) !Mesh {
        // reuse your staging logic (inline for now)
        const vertex_size = vertices.len * @sizeOf(Vertex);
        const index_size = indices.len * @sizeOf(u32);

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
            .index_count = @intCast(indices.len),
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
