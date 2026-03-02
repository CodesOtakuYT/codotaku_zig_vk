const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig").c;
const za = @import("zalgebra");
const Mat4 = za.Mat4;
const Vec3 = za.Vec3;

const Core = @import("core.zig").Core;
const Buffer = @import("buffer.zig");
const Mesh = @import("mesh.zig").Mesh;
const Vertex = @import("mesh.zig").Vertex;
const Texture = @import("texture.zig");
const GraphicsContext = @import("core.zig").GraphicsContext;
const Camera = @import("camera.zig");

const vert_spv align(@alignOf(u32)) = @embedFile("shaders/triangle.vert.spv").*;
const frag_spv align(@alignOf(u32)) = @embedFile("shaders/triangle.frag.spv").*;

const Self = @This();
core: Core,

// Application-specific resources
mesh: Mesh,
mesh_texture: Texture,
sampler: vk.Sampler,
uniform_buffer: Buffer,
descriptor_set_layout: vk.DescriptorSetLayout,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
camera: Camera,

start_ticks: u64,
should_quit: bool = false,

pub fn init(allocator: std.mem.Allocator) !Self {
    // 1. Plumbing
    var core = try Core.init(allocator, "Codotaku", 800, 600);
    errdefer core.deinit();

    const start_ticks = c.SDL_GetTicks();

    // 2. Load Assets
    var mesh = try Mesh.initObj(core.gc, core.command_pool, @embedFile("viking_room.obj"));
    errdefer mesh.deinit(core.gc);

    var mesh_texture = try Texture.createFromFile(core.gc, core.command_pool, "viking_room.png");
    errdefer mesh_texture.deinit(core.gc);

    // 3. Uniforms
    var uniform_buffer = try Buffer.init(core.gc, @sizeOf(Mat4), .{ .uniform_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
    errdefer uniform_buffer.deinit(core.gc);

    // 4. Sampler (All fields preserved)
    const sampler = try core.gc.dev.createSampler(&vk.SamplerCreateInfo{
        .mag_filter = .linear,
        .min_filter = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
        .compare_enable = .false,
        .compare_op = .always,
        .mipmap_mode = .linear,
        .mip_lod_bias = 0,
        .min_lod = 0,
        .max_lod = 0,
    }, null);
    errdefer core.gc.dev.destroySampler(sampler, null);

    // 5. Pipeline Setup
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex_bit = true } },
        .{ .binding = 1, .descriptor_type = .combined_image_sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
    };

    const dsl = try core.gc.dev.createDescriptorSetLayout(&.{
        .flags = .{ .push_descriptor_bit = true },
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);
    errdefer core.gc.dev.destroyDescriptorSetLayout(dsl, null);

    const pl = try core.gc.dev.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&dsl),
    }, null);
    errdefer core.gc.dev.destroyPipelineLayout(pl, null);

    const pipeline = try createPipeline(core.gc, pl, core.swapchain.surface_format.format);
    errdefer core.gc.dev.destroyPipeline(pipeline, null);

    return Self{
        .core = core,
        .mesh = mesh,
        .mesh_texture = mesh_texture,
        .sampler = sampler,
        .uniform_buffer = uniform_buffer,
        .descriptor_set_layout = dsl,
        .pipeline_layout = pl,
        .pipeline = pipeline,
        .start_ticks = start_ticks,
        .camera = Camera.init(Vec3.new(1.8, 1.8, 1.8), Vec3.new(0.0, 0.5, 0.0), Vec3.up()),
    };
}

pub fn deinit(self: *Self) void {
    self.core.gc.dev.deviceWaitIdle() catch {};
    self.core.gc.dev.destroySampler(self.sampler, null);
    self.mesh_texture.deinit(self.core.gc);
    self.core.gc.dev.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    self.core.gc.dev.destroyPipeline(self.pipeline, null);
    self.core.gc.dev.destroyPipelineLayout(self.pipeline_layout, null);
    self.uniform_buffer.deinit(self.core.gc);
    self.mesh.deinit(self.core.gc);
    self.core.deinit();
}

pub fn run(self: *Self) !void {
    while (!self.should_quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            self.camera.onEvent(event, self.core.window);
            if (event.type == c.SDL_EVENT_QUIT) self.should_quit = true;
        }

        const cmdbuf = (try self.core.beginFrame()) orelse {
            _ = c.SDL_WaitEvent(null);
            continue;
        };

        // Logic
        const current_ticks = c.SDL_GetTicks();
        // Calculate difference in milliseconds, then convert to seconds (f32)
        const dt = @as(f32, @floatFromInt(current_ticks - self.start_ticks)) / 1000.0;
        self.start_ticks = current_ticks;
        self.camera.update(dt);
        const mvp = self.camera.getDescriptorMatrix(self.core.swapchain.extent);
        try self.uniform_buffer.mapWrite(self.core.gc, Mat4, &.{mvp}, 0);

        // Draw
        try self.recordCommandBuffer(cmdbuf);

        try self.core.endFrame(cmdbuf);
    }
}

fn recordCommandBuffer(self: *Self, cmdbuf: vk.CommandBuffer) !void {
    const extent = self.core.swapchain.extent;

    // Begin
    try self.core.gc.dev.beginCommandBuffer(cmdbuf, &.{ .flags = .{ .one_time_submit_bit = true } });

    self.core.depth_texture.transitionLayout(self.core.gc.dev, cmdbuf, .depth_attachment_optimal);
    const swap_barrier = setupImageBarrier(self.core.swapchain.currentImage(), .undefined, .color_attachment_optimal, .{ .color_bit = true });
    self.core.gc.dev.cmdPipelineBarrier2(cmdbuf, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&swap_barrier),
    });

    // Rendering
    self.core.gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&vk.Viewport{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .min_depth = 0, .max_depth = 1 }));
    self.core.gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }));

    self.core.gc.dev.cmdBeginRendering(cmdbuf, &vk.RenderingInfo{
        .view_mask = 0,
        .layer_count = 1,
        .color_attachment_count = 1,
        .render_area = .{ .extent = extent, .offset = .{ .x = 0, .y = 0 } },
        .p_color_attachments = @ptrCast(&vk.RenderingAttachmentInfo{
            .image_view = self.core.swapchain.currentSwapImage().view,
            .image_layout = .color_attachment_optimal,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        }),
        .p_depth_attachment = &vk.RenderingAttachmentInfo{
            .image_view = self.core.depth_texture.view,
            .image_layout = .depth_attachment_optimal,
            .load_op = .clear,
            .store_op = .dont_care,
            .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        },
    });

    self.core.gc.dev.cmdBindPipeline(cmdbuf, .graphics, self.pipeline);

    // Push Descriptors
    const writes = [_]vk.WriteDescriptorSet{
        .{
            .dst_binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_buffer_info = @ptrCast(&vk.DescriptorBufferInfo{ .buffer = self.uniform_buffer.buffer, .offset = 0, .range = @sizeOf(Mat4) }),
            .dst_set = .null_handle,
            .dst_array_element = 0,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        .{
            .dst_binding = 1,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&vk.DescriptorImageInfo{ .sampler = self.sampler, .image_view = self.mesh_texture.view, .image_layout = .shader_read_only_optimal }),
            .dst_set = .null_handle,
            .dst_array_element = 0,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    };

    self.core.gc.dev.cmdPushDescriptorSet(cmdbuf, .graphics, self.pipeline_layout, 0, writes.len, &writes);
    self.mesh.draw(self.core.gc, cmdbuf);

    self.core.gc.dev.cmdEndRendering(cmdbuf);

    // Final Barrier for Present
    const present_barrier = setupImageBarrier(self.core.swapchain.currentImage(), .color_attachment_optimal, .present_src_khr, .{ .color_bit = true });
    self.core.gc.dev.cmdPipelineBarrier2(cmdbuf, &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = @ptrCast(&present_barrier) });

    try self.core.gc.dev.endCommandBuffer(cmdbuf);
}

// Helper to keep the recording code clean
fn setupImageBarrier(image: vk.Image, old: vk.ImageLayout, new: vk.ImageLayout, aspect: vk.ImageAspectFlags) vk.ImageMemoryBarrier2 {
    return .{
        .image = image,
        .old_layout = old,
        .new_layout = new,
        .src_access_mask = .{}, // Simplify: let the driver handle basic sync
        .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
        .src_stage_mask = .{ .all_commands_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .subresource_range = .{ .aspect_mask = aspect, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };
}

fn createPipeline(
    gc: *GraphicsContext,
    layout: vk.PipelineLayout,
    format: vk.Format,
) !vk.Pipeline {
    const vert = try gc.dev.createShaderModule(&.{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(&vert_spv),
    }, null);
    defer gc.dev.destroyShaderModule(vert, null);

    const frag = try gc.dev.createShaderModule(&.{
        .code_size = frag_spv.len,
        .p_code = @ptrCast(&frag_spv),
    }, null);
    defer gc.dev.destroyShaderModule(frag, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
    };

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined,
        .scissor_count = 1,
        .p_scissors = undefined,
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = false },
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const pipeline_rendering_create_info = vk.PipelineRenderingCreateInfo{
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&format),
        .depth_attachment_format = .d32_sfloat,
        .stencil_attachment_format = .undefined,
        .view_mask = 0,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .p_next = &pipeline_rendering_create_info,
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = &vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = .true,
            .depth_write_enable = .true, // Actually write the depth to the buffer
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = undefined, // Only needed if stencil_test_enable is TRUE
            .back = undefined,
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
        },
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = layout,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.dev.createGraphicsPipelines(
        .null_handle,
        1,
        @ptrCast(&gpci),
        null,
        @ptrCast(&pipeline),
    );
    return pipeline;
}
