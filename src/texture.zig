const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig").c;
const Buffer = @import("buffer.zig");
const GraphicsContext = @import("core.zig").GraphicsContext;

const Self = @This();

image: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,
extent: vk.Extent3D,
format: vk.Format,
layout: vk.ImageLayout,

/// Initializes a raw Vulkan image, allocates memory, and creates a default view.
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
        .initial_layout = .undefined,
    }, null);
    errdefer gc.dev.destroyImage(image, null);

    const mem_reqs = gc.dev.getImageMemoryRequirements(image);
    const memory = try gc.allocate(mem_reqs, memory_flags);
    errdefer gc.dev.freeMemory(memory, null);

    try gc.dev.bindImageMemory(image, memory, 0);

    const aspect_mask: vk.ImageAspectFlags = if (isDepthFormat(format))
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
        .layout = .undefined,
    };
}

pub fn deinit(self: Self, gc: *const GraphicsContext) void {
    gc.dev.destroyImageView(self.view, null);
    gc.dev.destroyImage(self.image, null);
    gc.dev.freeMemory(self.memory, null);
}

/// Generates a memory barrier for layout transitions using Synchronization2
pub fn transitionLayout(
    self: *Self,
    dev: vk.DeviceProxy,
    cmdbuf: vk.CommandBuffer,
    new_layout: vk.ImageLayout,
) void {
    const aspect_mask: vk.ImageAspectFlags = if (isDepthFormat(self.format))
        .{ .depth_bit = true }
    else
        .{ .color_bit = true };

    const barrier = vk.ImageMemoryBarrier2{
        .image = self.image,
        .old_layout = self.layout,
        .new_layout = new_layout,
        .src_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        .dst_access_mask = .{ .memory_read_bit = true, .memory_write_bit = true },
        .src_stage_mask = .{ .all_commands_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .subresource_range = .{
            .aspect_mask = aspect_mask,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
    };

    dev.cmdPipelineBarrier2(cmdbuf, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&barrier),
    });

    self.layout = new_layout;
}

/// Loads an image file via SDL3 and uploads it to GPU memory
pub fn createFromFile(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    path: [:0]const u8,
) !Self {
    const raw_image = try checkSDLPtr(c.SDL_Surface, c.SDL_LoadPNG(path));
    defer c.SDL_DestroySurface(raw_image);

    // Convert to RGBA32 for consistent mapping to VK_FORMAT_R8G8B8A8_SRGB
    const image = try checkSDLPtr(c.SDL_Surface, c.SDL_ConvertSurface(raw_image, c.SDL_PIXELFORMAT_RGBA32));
    defer c.SDL_DestroySurface(image);

    const width: u32 = @intCast(image.w);
    const height: u32 = @intCast(image.h);
    const extent = vk.Extent3D{ .width = width, .height = height, .depth = 1 };

    var self = try Self.init(
        gc,
        extent,
        .r8g8b8a8_srgb,
        .{ .transfer_dst_bit = true, .sampled_bit = true },
        .{ .device_local_bit = true },
    );
    errdefer self.deinit(gc);

    const bpp = 4;
    const row_size = width * bpp;
    const total_size = row_size * height;

    var staging = try Buffer.init(gc, total_size, .{ .transfer_src_bit = true }, .{
        .host_visible_bit = true,
        .host_coherent_bit = true,
    });
    defer staging.deinit(gc);

    const ptr = try gc.dev.mapMemory(staging.memory, 0, total_size, .{});
    defer gc.dev.unmapMemory(staging.memory);

    const dest_pixels: [*]u8 = @ptrCast(@alignCast(ptr));
    const src_pixels: [*]u8 = @ptrCast(@alignCast(image.pixels.?));

    // Handle potential SDL pitch padding
    for (0..height) |y| {
        const src_offset = y * @as(usize, @intCast(image.pitch));
        const dst_offset = y * row_size;
        @memcpy(dest_pixels[dst_offset .. dst_offset + row_size], src_pixels[src_offset .. src_offset + row_size]);
    }

    try self.copyFromBuffer(gc, pool, staging.buffer);

    return self;
}

fn copyFromBuffer(self: *Self, gc: *const GraphicsContext, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.dev.freeCommandBuffers(pool, 1, @ptrCast(&cmdbuf));

    try gc.dev.beginCommandBuffer(cmdbuf, &.{ .flags = .{ .one_time_submit_bit = true } });

    // Transition to Transfer Dst
    self.transitionLayout(gc.dev, cmdbuf, .transfer_dst_optimal);

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

    // Transition to Shader Read
    self.transitionLayout(gc.dev, cmdbuf, .shader_read_only_optimal);

    try gc.dev.endCommandBuffer(cmdbuf);

    const submit = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf)[0..1],
    };

    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&submit), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}

fn isDepthFormat(format: vk.Format) bool {
    return switch (format) {
        .d16_unorm, .d32_sfloat, .d16_unorm_s8_uint, .d24_unorm_s8_uint, .d32_sfloat_s8_uint => true,
        else => false,
    };
}

fn checkSDLPtr(comptime T: type, ptr: ?*T) !*T {
    if (ptr) |p| return p else return error.SDL;
}
