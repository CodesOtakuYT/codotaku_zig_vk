const vk = @import("vulkan");
const Buffer = @import("buffer.zig");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const za = @import("zalgebra");
const Vec3 = za.Vec3;
const Vec2 = za.Vec2;
const std = @import("std");
const obj = @import("obj");

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
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "uv"),
        },
    };

    pos: Vec3,
    uv: Vec2,
};

pub const Mesh = struct {
    vertex_buffer: Buffer,
    index_buffer: Buffer,
    index_count: u32,

    pub fn initObj(gc: *GraphicsContext, command_pool: vk.CommandPool, data: []const u8) !Mesh {
        var model = try obj.parseObj(gc.allocator, data);
        defer model.deinit(gc.allocator);

        var unique_vertices = std.AutoHashMap(obj.Mesh.Index, u32).init(gc.allocator);
        defer unique_vertices.deinit();

        var out_vertices = std.ArrayList(Vertex).empty;
        defer out_vertices.deinit(gc.allocator);
        var out_indices = std.ArrayList(u32).empty;
        defer out_indices.deinit(gc.allocator);

        for (model.meshes) |m| {
            var face_offset: usize = 0;
            for (m.num_vertices) |v_count| {
                // Triangulate polygons into a triangle fan
                for (0..v_count - 2) |i| {
                    const corner_indices = [_]usize{ 0, i + 1, i + 2 };

                    for (corner_indices) |idx_offset| {
                        const idx = m.indices[face_offset + idx_offset];
                        const result = try unique_vertices.getOrPut(idx);

                        if (!result.found_existing) {
                            const v_base = idx.vertex.? * 3;
                            const pos = Vec3.new(
                                model.vertices[v_base],
                                model.vertices[v_base + 1],
                                model.vertices[v_base + 2],
                            );

                            var uv = Vec2.new(0.0, 0.0);
                            if (idx.tex_coord) |t_idx| {
                                const t_base = t_idx * 2;
                                // Flip Y for Vulkan (OBJ is bottom-up, Vulkan is top-down)
                                uv = Vec2.new(
                                    model.tex_coords[t_base],
                                    1.0 - model.tex_coords[t_base + 1],
                                );
                            }

                            result.value_ptr.* = @intCast(out_vertices.items.len);
                            try out_vertices.append(gc.allocator, .{ .pos = pos, .uv = uv });
                        }
                        try out_indices.append(gc.allocator, result.value_ptr.*);
                    }
                }
                face_offset += v_count;
            }
        }

        return .init(gc, command_pool, out_vertices.items, out_indices.items);
    }

    pub fn initTorus(gc: *GraphicsContext, command_pool: vk.CommandPool) !Mesh {
        const main_segments = 64;
        const tube_segments = 32;
        const main_radius = 0.7;
        const tube_radius = 0.3;

        var vertices = std.ArrayList(Vertex).empty;
        defer vertices.deinit(gc.allocator);
        var indices = std.ArrayList(u32).empty;
        defer indices.deinit(gc.allocator);

        for (0..main_segments + 1) |i| {
            const u_frac = @as(f32, @floatFromInt(i)) / main_segments;
            const u = u_frac * 2.0 * std.math.pi;

            for (0..tube_segments + 1) |j| {
                const v_frac = @as(f32, @floatFromInt(j)) / tube_segments;
                const v = v_frac * 2.0 * std.math.pi;

                const x = (main_radius + tube_radius * std.math.cos(v)) * std.math.cos(u);
                const y = (main_radius + tube_radius * std.math.cos(v)) * std.math.sin(u);
                const z = tube_radius * std.math.sin(v);

                try vertices.append(gc.allocator, .{
                    .pos = Vec3.new(x, y, z),
                    .uv = Vec2.new(u_frac, v_frac),
                });
            }
        }

        for (0..main_segments) |i| {
            for (0..tube_segments) |j| {
                const first = @as(u32, @intCast(i * (tube_segments + 1) + j));
                const second = first + tube_segments + 1;

                try indices.append(gc.allocator, first);
                try indices.append(gc.allocator, second);
                try indices.append(gc.allocator, first + 1);

                try indices.append(gc.allocator, second);
                try indices.append(gc.allocator, second + 1);
                try indices.append(gc.allocator, first + 1);
            }
        }

        return .init(gc, command_pool, vertices.items, indices.items);
    }

    pub fn initCube(gc: *GraphicsContext, command_pool: vk.CommandPool) !Mesh {
        const vertices = [_]Vertex{
            // Front
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .uv = Vec2.new(0, 1) },
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .uv = Vec2.new(1, 1) },
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .uv = Vec2.new(1, 0) },
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .uv = Vec2.new(0, 0) },
            // Back
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .uv = Vec2.new(0, 1) },
            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .uv = Vec2.new(1, 1) },
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .uv = Vec2.new(1, 0) },
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .uv = Vec2.new(0, 0) },
            // Top
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .uv = Vec2.new(0, 1) },
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .uv = Vec2.new(1, 1) },
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .uv = Vec2.new(1, 0) },
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .uv = Vec2.new(0, 0) },
            // Bottom
            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .uv = Vec2.new(0, 1) },
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .uv = Vec2.new(1, 1) },
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .uv = Vec2.new(1, 0) },
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .uv = Vec2.new(0, 0) },
            // Right
            .{ .pos = Vec3.new(0.5, -0.5, 0.5), .uv = Vec2.new(0, 1) },
            .{ .pos = Vec3.new(0.5, -0.5, -0.5), .uv = Vec2.new(1, 1) },
            .{ .pos = Vec3.new(0.5, 0.5, -0.5), .uv = Vec2.new(1, 0) },
            .{ .pos = Vec3.new(0.5, 0.5, 0.5), .uv = Vec2.new(0, 0) },
            // Left
            .{ .pos = Vec3.new(-0.5, -0.5, -0.5), .uv = Vec2.new(0, 1) },
            .{ .pos = Vec3.new(-0.5, -0.5, 0.5), .uv = Vec2.new(1, 1) },
            .{ .pos = Vec3.new(-0.5, 0.5, 0.5), .uv = Vec2.new(1, 0) },
            .{ .pos = Vec3.new(-0.5, 0.5, -0.5), .uv = Vec2.new(0, 0) },
        };

        var indices: [36]u32 = undefined;
        for (0..6) |i| {
            const base_v = @as(u32, @intCast(i * 4));
            const base_i = i * 6;
            indices[base_i + 0] = base_v + 0;
            indices[base_i + 1] = base_v + 1;
            indices[base_i + 2] = base_v + 2;
            indices[base_i + 3] = base_v + 2;
            indices[base_i + 4] = base_v + 3;
            indices[base_i + 5] = base_v + 0;
        }

        return .init(gc, command_pool, &vertices, &indices);
    }

    pub fn init(gc: *GraphicsContext, command_pool: vk.CommandPool, vertices: []const Vertex, indices: []const u32) !Mesh {
        const vertex_size = vertices.len * @sizeOf(Vertex);
        const index_size = indices.len * @sizeOf(u32);

        var staging = try Buffer.init(
            gc,
            vertex_size + index_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        defer staging.deinit(gc);

        try staging.mapWrite(gc, Vertex, vertices, 0);
        try staging.mapWrite(gc, u32, indices, vertex_size);

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

        // Ensure GPU copy is done before CPU destroys staging
        try gc.dev.deviceWaitIdle();

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
