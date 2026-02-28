const vk = @import("vulkan");
const std = @import("std");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

const Self = @This();
buffer: vk.Buffer,
memory: vk.DeviceMemory,
size: vk.DeviceSize,

pub fn init(
    gc: *const GraphicsContext,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    memory_flags: vk.MemoryPropertyFlags,
) !Self {
    const buffer = try gc.dev.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);

    errdefer gc.dev.destroyBuffer(buffer, null);

    const mem_reqs = gc.dev.getBufferMemoryRequirements(buffer);
    const memory = try gc.allocate(mem_reqs, memory_flags);
    errdefer gc.dev.freeMemory(memory, null);

    try gc.dev.bindBufferMemory(buffer, memory, 0);

    return Self{
        .buffer = buffer,
        .memory = memory,
        .size = size,
    };
}

pub fn deinit(self: *Self, gc: *const GraphicsContext) void {
    gc.dev.destroyBuffer(self.buffer, null);
    gc.dev.freeMemory(self.memory, null);
}

pub fn mapWrite(
    self: *Self,
    gc: *const GraphicsContext,
    comptime T: type,
    data: []const T,
    offset: vk.DeviceSize,
) !void {
    const ptr = try gc.dev.mapMemory(self.memory, offset, @sizeOf(@TypeOf(data)), .{});
    defer gc.dev.unmapMemory(self.memory);

    const typed: [*]T = @ptrCast(@alignCast(ptr));
    @memcpy(typed, data);
}

pub fn copyTo(
    self: *const Self,
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    dst: Self,
    offset: vk.DeviceSize,
) !void {
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
        .src_offset = offset,
        .dst_offset = 0,
        .size = dst.size,
    };

    cmdbuf.copyBuffer(self.buffer, dst.buffer, 1, @ptrCast(&region));

    try cmdbuf.endCommandBuffer();

    const submit = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = (&cmdbuf.handle)[0..1],
    };

    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&submit), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);
}
