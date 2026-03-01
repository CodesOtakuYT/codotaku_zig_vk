const vk = @import("vulkan");
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

const Self = @This();

image: vk.Image,
view: vk.ImageView,
memory: vk.DeviceMemory,

pub fn init(
    gc: *GraphicsContext,
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

    // Determine aspect mask based on format
    const aspect_mask: vk.ImageAspectFlags = if (format == .d32_sfloat or format == .d16_unorm)
        .{ .depth_bit = true }
    else
        .{ .color_bit = true };

    const view = try gc.dev.createImageView(&vk.ImageViewCreateInfo{
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

    return Self{
        .image = image,
        .view = view,
        .memory = memory,
    };
}

pub fn deinit(self: Self, gc: *GraphicsContext) void {
    gc.dev.destroyImageView(self.view, null);
    gc.dev.destroyImage(self.image, null);
    gc.dev.freeMemory(self.memory, null);
}
