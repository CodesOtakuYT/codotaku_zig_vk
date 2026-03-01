const vk = @import("vulkan");
const c = @import("c.zig").c;
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const Buffer = @import("buffer.zig");
const za = @import("zalgebra");
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;
const Mesh = @import("mesh.zig").Mesh;
const Vertex = @import("mesh.zig").Vertex;
const Texture = @import("texture.zig");

const vert_spv align(@alignOf(u32)) = @embedFile("shaders/triangle.vert.spv").*;
const frag_spv align(@alignOf(u32)) = @embedFile("shaders/triangle.frag.spv").*;

fn errorSDL() !void {
    std.log.err("SDL Error: {s}", .{c.SDL_GetError()});
    return error.SDL;
}

fn checkSDL(ret: bool) !void {
    if (!ret)
        try errorSDL();
}

fn checkSDLPtr(comptime T: type, ptr: ?*T) !*T {
    if (ptr) |p| {
        return p;
    } else {
        try errorSDL();
        unreachable;
    }
}

const App = @This();

allocator: std.mem.Allocator,
window: *c.SDL_Window,
gc: GraphicsContext,
swapchain: Swapchain,
command_pool: vk.CommandPool,
cmdbufs: []vk.CommandBuffer,
mesh: Mesh,
depth_texture: Texture,
mesh_texture: Texture,
sampler: vk.Sampler,
uniform_buffer: Buffer,
descriptor_set_layout: vk.DescriptorSetLayout,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
state: Swapchain.PresentState = .optimal,
should_quit: bool = false,
start_ticks: u64,

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub fn init(allocator: std.mem.Allocator) !App {
    const start_ticks = c.SDL_GetTicks();

    try checkSDL(c.SDL_Init(c.SDL_INIT_VIDEO));
    errdefer c.SDL_Quit();

    try checkSDL(c.SDL_Vulkan_LoadLibrary(null));
    errdefer c.SDL_Vulkan_UnloadLibrary();

    const window = try checkSDLPtr(c.SDL_Window, c.SDL_CreateWindow("Codotaku", 800, 600, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIDDEN));
    errdefer c.SDL_DestroyWindow(window);

    try checkSDL(c.SDL_ShowWindow(window));

    var gc = try GraphicsContext.init(allocator, "Codotaku", window);
    errdefer gc.deinit();

    var swapchain = try Swapchain.init(&gc, allocator, .{ .width = 800, .height = 600 });
    errdefer swapchain.deinit();

    const command_pool = try gc.dev.createCommandPool(&vk.CommandPoolCreateInfo{
        .queue_family_index = gc.graphics_queue.family,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
    errdefer gc.dev.destroyCommandPool(command_pool, null);

    const cmdbufs = try allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    errdefer allocator.free(cmdbufs);

    try gc.dev.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer gc.dev.freeCommandBuffers(command_pool, @intCast(cmdbufs.len), cmdbufs.ptr);

    const mesh = try Mesh.initObj(&gc, command_pool, @embedFile("viking_room.obj"));

    const mvp = makeMVP(0.0, swapchain.extent);

    var uniform_buffer = try Buffer.init(
        &gc,
        @sizeOf(Mat4),
        .{ .uniform_buffer_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    );
    errdefer uniform_buffer.deinit(&gc);

    try uniform_buffer.mapWrite(&gc, Mat4, &.{mvp}, 0);

    const sampler = try gc.dev.createSampler(&vk.SamplerCreateInfo{
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
    errdefer gc.dev.destroySampler(sampler, null);

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true },
        },
        .{
            .binding = 1,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        },
    };

    const descriptor_set_layout = try gc.dev.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
        .flags = vk.DescriptorSetLayoutCreateFlags{ .push_descriptor_bit = true },
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    }, null);

    const swapchain_extent = swapchain.extent;
    const depth_texture = try Texture.init(&gc, .{ .width = swapchain_extent.width, .height = swapchain_extent.height, .depth = 1 }, vk.Format.d32_sfloat, .{ .depth_stencil_attachment_bit = true }, .{
        .device_local_bit = true,
    });
    errdefer depth_texture.deinit(&gc);

    const image = try checkSDLPtr(c.SDL_Surface, c.SDL_LoadPNG("viking_room.png"));
    defer c.SDL_DestroySurface(image);

    const mesh_texture = try Texture.createFromFile(&gc, command_pool, "viking_room.png");

    const pipeline_layout = try gc.dev.createPipelineLayout(&vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&descriptor_set_layout),
    }, null);
    errdefer gc.dev.destroyPipelineLayout(pipeline_layout, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, swapchain.surface_format.format);
    errdefer gc.dev.destroyPipeline(pipeline, null);

    return App{
        .allocator = allocator,
        .window = window,
        .gc = gc,
        .swapchain = swapchain,
        .command_pool = command_pool,
        .cmdbufs = cmdbufs,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .uniform_buffer = uniform_buffer,
        .descriptor_set_layout = descriptor_set_layout,
        .mesh = mesh,
        .start_ticks = start_ticks,
        .depth_texture = depth_texture,
        .mesh_texture = mesh_texture,
        .sampler = sampler,
    };
}

pub fn deinit(self: *App) void {
    self.gc.dev.deviceWaitIdle() catch {};

    self.gc.dev.destroySampler(self.sampler, null);
    self.mesh_texture.deinit(&self.gc);
    self.depth_texture.deinit(&self.gc);
    self.gc.dev.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    self.gc.dev.destroyPipeline(self.pipeline, null);
    self.gc.dev.destroyPipelineLayout(self.pipeline_layout, null);
    self.uniform_buffer.deinit(&self.gc);
    self.mesh.deinit(&self.gc);
    self.gc.dev.freeCommandBuffers(self.command_pool, @intCast(self.cmdbufs.len), self.cmdbufs.ptr);
    self.gc.dev.destroyCommandPool(self.command_pool, null);
    self.allocator.free(self.cmdbufs);
    self.swapchain.deinit();
    self.gc.deinit();
    c.SDL_DestroyWindow(self.window);
    c.SDL_Vulkan_UnloadLibrary();
    c.SDL_Quit();
}

pub fn run(self: *App) !void {
    while (!self.should_quit) {
        const now = c.SDL_GetTicks();
        const time = @as(f32, @floatFromInt(now - self.start_ticks)) / 1000.0;

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => self.should_quit = true,
                else => {},
            }
        }

        var w: c_int = undefined;
        var h: c_int = undefined;
        try checkSDL(c.SDL_GetWindowSizeInPixels(self.window, &w, &h));

        if (w == 0 or h == 0) {
            _ = c.SDL_WaitEvent(null);
            continue;
        }

        var extent = self.swapchain.extent;
        if (self.state == .suboptimal or extent.width != @as(u32, @intCast(w)) or extent.height != @as(u32, @intCast(h))) {
            extent.width = @intCast(w);
            extent.height = @intCast(h);
            try self.gc.dev.deviceWaitIdle();
            try self.swapchain.recreate(extent);
            self.state = .optimal;

            self.depth_texture.deinit(&self.gc);
            self.depth_texture = try Texture.init(&self.gc, .{ .width = extent.width, .height = extent.height, .depth = 1 }, vk.Format.d32_sfloat, .{ .depth_stencil_attachment_bit = true }, .{
                .device_local_bit = true,
            });
        }

        const current = self.swapchain.currentSwapImage();
        try current.waitForFence(&self.gc);
        try self.gc.dev.resetFences(1, @ptrCast(&current.frame_fence));

        const mvp = makeMVP(time, self.swapchain.extent);
        try self.uniform_buffer.mapWrite(&self.gc, Mat4, &.{mvp}, 0);

        const cmdbuf = self.cmdbufs[self.swapchain.image_index];
        try self.gc.dev.resetCommandBuffer(cmdbuf, .{});

        try self.recordCommandBuffer(cmdbuf);

        self.state = self.swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => return err,
        };
    }

    try self.gc.dev.deviceWaitIdle();
}

fn recordCommandBuffer(self: *@This(), cmdbuf: vk.CommandBuffer) !void {
    const extent = self.swapchain.extent;
    const current = self.swapchain.currentSwapImage();

    try self.gc.dev.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{
        .flags = .{ .one_time_submit_bit = true },
    });

    const image_barriers = [_]vk.ImageMemoryBarrier2{
        // Barrier for the Swapchain Color Image
        .{
            .image = self.swapchain.currentImage(),
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .src_access_mask = .{},
            .dst_access_mask = .{ .color_attachment_write_bit = true },
            .src_stage_mask = .{ .top_of_pipe_bit = true },
            .dst_stage_mask = .{ .color_attachment_output_bit = true },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
        // Barrier for the Depth Texture
        .{
            .image = self.depth_texture.image,
            .old_layout = .undefined,
            .new_layout = .depth_attachment_optimal,
            .src_access_mask = .{},
            .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
            .src_stage_mask = .{ .early_fragment_tests_bit = true },
            .dst_stage_mask = .{ .early_fragment_tests_bit = true },
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        },
    };

    self.gc.dev.cmdPipelineBarrier2(cmdbuf, &vk.DependencyInfo{
        .image_memory_barrier_count = image_barriers.len,
        .p_image_memory_barriers = &image_barriers,
    });

    self.gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&vk.Viewport{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .min_depth = 0, .max_depth = 1 }));
    self.gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent }));

    self.gc.dev.cmdBeginRendering(cmdbuf, &vk.RenderingInfo{
        .layer_count = 1,
        .color_attachment_count = 1,
        .render_area = .{
            .extent = extent,
            .offset = .{ .x = 0, .y = 0 },
        },
        .p_color_attachments = @ptrCast(&vk.RenderingAttachmentInfo{
            .clear_value = .{
                .color = .{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } },
            },
            .image_view = current.view,
            .image_layout = .color_attachment_optimal,
            .load_op = .clear,
            .store_op = .store,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        }),
        .p_depth_attachment = &vk.RenderingAttachmentInfo{
            .image_view = self.depth_texture.view,
            .image_layout = .depth_attachment_optimal,
            .load_op = .clear,
            .store_op = .dont_care,
            .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
        },
        .view_mask = 0,
    });

    self.gc.dev.cmdBindPipeline(cmdbuf, .graphics, self.pipeline);

    const buffer_info = vk.DescriptorBufferInfo{
        .buffer = self.uniform_buffer.buffer,
        .offset = 0,
        .range = @sizeOf(Mat4),
    };

    const image_info = vk.DescriptorImageInfo{
        .sampler = self.sampler,
        .image_view = self.mesh_texture.view,
        .image_layout = .shader_read_only_optimal,
    };

    const writes = [_]vk.WriteDescriptorSet{
        .{
            .dst_binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_buffer_info = @ptrCast(&buffer_info),
            .dst_set = .null_handle,
            .dst_array_element = 0,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        .{
            .dst_binding = 1,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info),
            .dst_set = .null_handle,
            .dst_array_element = 0,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    };

    self.gc.dev.cmdPushDescriptorSet(
        cmdbuf,
        .graphics,
        self.pipeline_layout,
        0,
        writes.len,
        &writes,
    );
    self.mesh.draw(&self.gc, cmdbuf);
    self.gc.dev.cmdEndRendering(cmdbuf);

    self.gc.dev.cmdPipelineBarrier2(cmdbuf, &vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&vk.ImageMemoryBarrier2{
            .image = self.swapchain.currentImage(),
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_access_mask = .{},
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .dst_stage_mask = .{ .bottom_of_pipe_bit = true },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .layer_count = 1,
                .level_count = 1,
                .base_array_layer = 0,
                .base_mip_level = 0,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        }),
    });

    try self.gc.dev.endCommandBuffer(cmdbuf);
}

fn createPipeline(
    gc: *const GraphicsContext,
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

pub fn makeMVP(time: f32, swapchain_extent: vk.Extent2D) Mat4 {
    // 1. Projection: Keeping the standard FOV
    var projection = za.perspective(45.0, @as(f32, @floatFromInt(swapchain_extent.width)) / @as(f32, @floatFromInt(swapchain_extent.height)), 0.1, 100.0);
    projection.data[1][1] *= -1; // Vulkan Y-flip

    // 2. View: Move the camera MUCH closer to fill the screen
    // Moved from (3,3,3) to (1.8, 1.8, 1.8) for a closer look
    const eye = Vec3.new(1.8, 1.8, 1.8);
    const target = Vec3.new(0.0, 0.5, 0.0); // Look slightly up from the floor
    const up = Vec3.up();
    const view = za.lookAt(eye, target, up);

    // 3. Model: Fixing orientation and increasing speed
    // Apply a 90 degree fix on X to stand it up
    const fix_rotation = Mat4.fromRotation(-90.0, Vec3.right());

    // Increased rotation speed to 30.0 for a more lively view
    const angle = time * 30.0;
    const spin = Mat4.fromRotation(angle, Vec3.up());

    // Combine: Spin it while it's standing up
    const model = spin.mul(fix_rotation);

    return projection.mul(view).mul(model);
}
