const vk = @import("vulkan");
const c = @import("c.zig").c;
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;

const Vertex = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    color: [3]f32,
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

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
buffer: vk.Buffer,
buffer_memory: vk.DeviceMemory,
pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
state: Swapchain.PresentState = .optimal,
should_quit: bool = false,

pub fn init(allocator: std.mem.Allocator) !App {
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

    const buffer = try gc.dev.createBuffer(&.{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer gc.dev.destroyBuffer(buffer, null);

    const mem_reqs = gc.dev.getBufferMemoryRequirements(buffer);
    const memory = try gc.allocate(mem_reqs, .{ .device_local_bit = true });
    errdefer gc.dev.freeMemory(memory, null);
    try gc.dev.bindBufferMemory(buffer, memory, 0);

    try uploadVertices(&gc, command_pool, buffer);

    const pipeline_layout = try gc.dev.createPipelineLayout(&vk.PipelineLayoutCreateInfo{}, null);
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
        .buffer = buffer,
        .buffer_memory = memory,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: *App) void {
    self.gc.dev.deviceWaitIdle() catch {};

    self.gc.dev.destroyPipeline(self.pipeline, null);
    self.gc.dev.destroyPipelineLayout(self.pipeline_layout, null);
    self.gc.dev.freeMemory(self.buffer_memory, null);
    self.gc.dev.destroyBuffer(self.buffer, null);
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
        }

        const current = self.swapchain.currentSwapImage();
        try current.waitForFence(&self.gc);
        try self.gc.dev.resetFences(1, @ptrCast(&current.frame_fence));

        const cmdbuf = self.cmdbufs[self.swapchain.image_index];
        try self.gc.dev.resetCommandBuffer(cmdbuf, .{});

        try self.gc.dev.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{
            .flags = .{ .one_time_submit_bit = true },
        });

        self.gc.dev.cmdPipelineBarrier2(cmdbuf, &vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&vk.ImageMemoryBarrier2{
                .image = self.swapchain.currentImage(),
                .old_layout = .undefined,
                .new_layout = .color_attachment_optimal,
                .src_access_mask = .{},
                .dst_access_mask = .{ .color_attachment_write_bit = true },
                .src_stage_mask = .{ .top_of_pipe_bit = true },
                .dst_stage_mask = .{ .color_attachment_output_bit = true },
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
            .view_mask = 0,
        });

        self.gc.dev.cmdBindPipeline(cmdbuf, .graphics, self.pipeline);
        const offsets = [_]vk.DeviceSize{0};
        self.gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&self.buffer), &offsets);
        self.gc.dev.cmdDraw(cmdbuf, 3, 1, 0, 0);
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

        self.state = self.swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => return err,
        };
    }

    try self.gc.dev.deviceWaitIdle();
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
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
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
        .depth_attachment_format = .undefined,
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
        .p_depth_stencil_state = null,
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

fn uploadVertices(gc: *const GraphicsContext, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    const staging_buffer = try gc.dev.createBuffer(&.{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer gc.dev.destroyBuffer(staging_buffer, null);

    const mem_reqs = gc.dev.getBufferMemoryRequirements(staging_buffer);
    const staging_memory = try gc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer gc.dev.freeMemory(staging_memory, null);
    try gc.dev.bindBufferMemory(staging_buffer, staging_memory, 0);

    {
        const data = try gc.dev.mapMemory(staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer gc.dev.unmapMemory(staging_memory);

        const gpu_vertices: [*]Vertex = @ptrCast(@alignCast(data));
        @memcpy(gpu_vertices, vertices[0..]);
    }

    try copyBuffer(gc, pool, buffer, staging_buffer, @sizeOf(@TypeOf(vertices)));
}

fn copyBuffer(gc: *const GraphicsContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));
    defer gc.dev.freeCommandBuffers(pool, 1, @ptrCast(&cmdbuf_handle));

    const cmdbuf = GraphicsContext.CommandBuffer.init(cmdbuf_handle, gc.dev.wrapper);

    try cmdbuf.beginCommandBuffer(&.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    cmdbuf.copyBuffer(src, dst, 1, @ptrCast(&region));

    try cmdbuf.endCommandBuffer();

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}
