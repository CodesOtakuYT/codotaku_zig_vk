const vk = @import("vulkan");
const c = @import("c.zig").c;
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;

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

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}).init;
    defer std.debug.assert(gpa_allocator.deinit() == .ok);

    const gpa = gpa_allocator.allocator();

    try checkSDL(c.SDL_Init(c.SDL_INIT_VIDEO));

    try checkSDL(c.SDL_Vulkan_LoadLibrary(null));

    const window = try checkSDLPtr(c.SDL_Window, c.SDL_CreateWindow("Codotaku", 800, 600, c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIDDEN));
    try checkSDL(c.SDL_ShowWindow(window));

    var gc = try GraphicsContext.init(gpa, "Codotaku", window);
    defer gc.deinit();

    var swapchain = try Swapchain.init(&gc, gpa, .{ .width = 800, .height = 600 });
    defer swapchain.deinit();

    const command_pool = try gc.dev.createCommandPool(&vk.CommandPoolCreateInfo{ .queue_family_index = gc.graphics_queue.family, .flags = .{
        .reset_command_buffer_bit = true,
    } }, null);
    defer gc.dev.destroyCommandPool(command_pool, null);

    const cmdbufs = try gpa.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    defer gpa.free(cmdbufs);

    try gc.dev.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(cmdbufs.len),
    }, cmdbufs.ptr);
    defer gc.dev.freeCommandBuffers(command_pool, @intCast(cmdbufs.len), cmdbufs.ptr);

    const pipeline_layout = try gc.dev.createPipelineLayout(&vk.PipelineLayoutCreateInfo{}, null);

    const pipeline = try createPipeline(&gc, pipeline_layout, swapchain.surface_format.format);

    var state: Swapchain.PresentState = .optimal;
    var should_quit: bool = false;

    while (!should_quit) {
        var w: c_int = undefined;
        var h: c_int = undefined;
        try checkSDL(c.SDL_GetWindowSizeInPixels(window, &w, &h));

        // Don't present or resize swapchain while the window is minimized
        if (w == 0 or h == 0) {
            try checkSDL(c.SDL_WaitEvent(null));
            continue;
        }

        var extent = swapchain.extent;

        if (state == .suboptimal or extent.width != @as(u32, @intCast(w)) or extent.height != @as(u32, @intCast(h))) {
            extent.width = @intCast(w);
            extent.height = @intCast(h);
            try gc.dev.deviceWaitIdle();
            try swapchain.recreate(extent);
        }

        const current = swapchain.currentSwapImage();
        try current.waitForFence(&gc);
        try gc.dev.resetFences(1, @ptrCast(&current.frame_fence));

        const cmdbuf = cmdbufs[swapchain.image_index];
        try gc.dev.resetCommandBuffer(cmdbuf, .{});

        try gc.dev.beginCommandBuffer(cmdbuf, &vk.CommandBufferBeginInfo{
            .flags = .{
                .one_time_submit_bit = true,
            },
        });

        gc.dev.cmdPipelineBarrier2(cmdbuf, &vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&vk.ImageMemoryBarrier2{
                .image = swapchain.currentImage(),
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

        gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&vk.Viewport{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .min_depth = 0, .max_depth = 1 }));
        gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = swapchain.extent }));

        gc.dev.cmdBeginRendering(cmdbuf, &vk.RenderingInfo{
            .layer_count = 1,
            .color_attachment_count = 1,
            .render_area = .{
                .extent = extent,
                .offset = .{ .x = 0, .y = 0 },
            },
            .p_color_attachments = @ptrCast(&vk.RenderingAttachmentInfo{
                .clear_value = .{
                    .color = .{
                        .float_32 = .{ 1.0, 0.0, 0.0, 1.0 },
                    },
                },
                .image_view = swapchain.currentSwapImage().view,
                .image_layout = .color_attachment_optimal,
                .load_op = .clear,
                .store_op = .store,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
            }),
            .view_mask = 0,
        });

        gc.dev.cmdBindPipeline(cmdbuf, .graphics, pipeline);
        gc.dev.cmdDraw(cmdbuf, 3, 1, 0, 0);
        gc.dev.cmdEndRendering(cmdbuf);

        gc.dev.cmdPipelineBarrier2(cmdbuf, &vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&vk.ImageMemoryBarrier2{
                .image = swapchain.currentImage(),
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

        try gc.dev.endCommandBuffer(cmdbuf);

        state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) switch (event.type) {
            c.SDL_EVENT_QUIT => {
                should_quit = true;
            },
            else => {},
        };
    }

    try swapchain.waitForAllFences();
    try gc.dev.deviceWaitIdle();
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

    const pvisci = vk.PipelineVertexInputStateCreateInfo{};

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
        .scissor_count = 1,
        .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
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
