const vk = @import("vulkan");
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Buffer = @import("buffer.zig");
const c = @import("c.zig").c;

const Self = @This();

image: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,
extent: vk.Extent3D,
format: vk.Format,

/// Helper to wrap common SDL surface loading logic
fn checkSDLPtr(comptime T: type, ptr: ?*T) !*T {
    if (ptr) |p| return p else return error.SDL;
}

pub fn init(
    gc: *const GraphicsContext,
    extent: vk.Extent3D,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    memory_flags: vk.MemoryPropertyFlags,
) !Self {
    const image = try gc.dev.createImage(&vk.ImageCreateInfo{
        .flags = .{},
        .image_type = .@"2d",
        .format = format,
        .extent = extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    }, null);
    errdefer gc.dev.destroyImage(image, null);

    const mem_reqs = gc.dev.getImageMemoryRequirements(image);
    const memory = try gc.allocate(mem_reqs, memory_flags);
    errdefer gc.dev.freeMemory(memory, null);

    try gc.dev.bindImageMemory(image, memory, 0);

    // Determine aspect mask: Depth textures need .depth_bit, Colors need .color_bit
    const aspect_mask: vk.ImageAspectFlags = if (format == .d32_sfloat or format == .d16_unorm)
        .{ .depth_bit = true }
    else
        .{ .color_bit = true };

    const view = try gc.dev.createImageView(&vk.ImageViewCreateInfo{
        .flags = .{},
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
    errdefer gc.dev.destroyImageView(view, null);

    return Self{
        .image = image,
        .view = view,
        .memory = memory,
        .extent = extent,
        .format = format,
    };
}

pub fn deinit(self: Self, gc: *const GraphicsContext) void {
    gc.dev.destroyImageView(self.view, null);
    gc.dev.destroyImage(self.image, null);
    gc.dev.freeMemory(self.memory, null);
}

/// Loads a PNG/Image file, converts to RGBA32, and uploads to GPU memory via staging
pub fn createFromFile(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    path: [:0]const u8,
) !Self {
    // 1. Load image using SDL3
    const raw_image = try checkSDLPtr(c.SDL_Surface, c.SDL_LoadPNG(path));
    defer c.SDL_DestroySurface(raw_image);

    // 2. Convert to RGBA32 to ensure byte-order matches VK_FORMAT_R8G8B8A8_UNORM
    const image = try checkSDLPtr(c.SDL_Surface, c.SDL_ConvertSurface(raw_image, c.SDL_PIXELFORMAT_RGBA32));
    defer c.SDL_DestroySurface(image);

    const width: u32 = @intCast(image.w);
    const height: u32 = @intCast(image.h);
    const extent = vk.Extent3D{ .width = width, .height = height, .depth = 1 };

    // 3. Create the actual GPU Texture
    const self = try Self.init(
        gc,
        extent,
        .r8g8b8a8_srgb,
        .{ .transfer_dst_bit = true, .sampled_bit = true },
        .{ .device_local_bit = true },
    );
    errdefer self.deinit(gc);

    // 4. Staging Buffer Setup
    const bpp = 4; // 4 bytes per pixel (RGBA)
    const row_size = width * bpp;
    const total_size = row_size * height;

    var staging = try Buffer.init(gc, total_size, .{ .transfer_src_bit = true }, .{
        .host_visible_bit = true,
        .host_coherent_bit = true,
    });
    defer staging.deinit(gc);

    // Copy row-by-row to the staging buffer to strip any SDL pitch/padding
    const ptr = try gc.dev.mapMemory(staging.memory, 0, total_size, .{});
    defer gc.dev.unmapMemory(staging.memory);

    const dest_pixels: [*]u8 = @ptrCast(@alignCast(ptr));
    const src_pixels: [*]u8 = @ptrCast(@alignCast(image.pixels.?));

    for (0..height) |y| {
        const src_offset = y * @as(usize, @intCast(image.pitch));
        const dst_offset = y * row_size;
        @memcpy(
            dest_pixels[dst_offset .. dst_offset + row_size],
            src_pixels[src_offset .. src_offset + row_size],
        );
    }

    // 5. Submit the copy command to the GPU
    try self.copyFromBuffer(gc, pool, staging.buffer);

    return self;
}

fn copyFromBuffer(self: Self, gc: *const GraphicsContext, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.dev.freeCommandBuffers(pool, 1, @ptrCast(&cmdbuf));

    try gc.dev.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    // Layout Transition: Undefined -> Transfer Destination
    insertImageBarrier(gc.dev, cmdbuf, self.image, range, .undefined, .transfer_dst_optimal, .{}, .{ .transfer_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .all_transfer_bit = true });

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = self.extent,
    };

    gc.dev.cmdCopyBufferToImage(cmdbuf, buffer, self.image, .transfer_dst_optimal, 1, @ptrCast(&region));

    // Layout Transition: Transfer Destination -> Shader Read Only (ready for Fragment Shader)
    insertImageBarrier(gc.dev, cmdbuf, self.image, range, .transfer_dst_optimal, .shader_read_only_optimal, .{ .transfer_write_bit = true }, .{ .shader_read_bit = true }, .{
        .all_transfer_bit = true,
    }, .{ .fragment_shader_bit = true });

    try gc.dev.endCommandBuffer(cmdbuf);

    const submit = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf)[0..1],
    };

    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&submit), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

fn insertImageBarrier(
    dev: vk.DeviceProxy,
    cmdbuf: vk.CommandBuffer,
    image: vk.Image,
    range: vk.ImageSubresourceRange,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access: vk.AccessFlags2,
    dst_access: vk.AccessFlags2,
    src_stage: vk.PipelineStageFlags2,
    dst_stage: vk.PipelineStageFlags2,
) void {
    const barrier = vk.ImageMemoryBarrier2{
        .image = image,
        .subresource_range = range,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .src_stage_mask = src_stage,
        .dst_stage_mask = dst_stage,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };
    dev.cmdPipelineBarrier2(cmdbuf, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    });
}
