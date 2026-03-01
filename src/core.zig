const std = @import("std");
const vk = @import("vulkan");
const c = @import("c.zig").c;
pub const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Swapchain = @import("swapchain.zig").Swapchain;
const Texture = @import("texture.zig");

pub const Core = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    // Pointer ensures the dispatch table and device handles stay at a fixed address
    gc: *GraphicsContext,
    swapchain: Swapchain,
    depth_texture: Texture,
    command_pool: vk.CommandPool,
    cmdbufs: []vk.CommandBuffer,

    resizing: bool = false,

    pub fn init(allocator: std.mem.Allocator, title: [*:0]const u8, width: u32, height: u32) !Core {
        try checkSDL(c.SDL_Init(c.SDL_INIT_VIDEO));
        errdefer c.SDL_Quit();

        try checkSDL(c.SDL_Vulkan_LoadLibrary(null));
        errdefer c.SDL_Vulkan_UnloadLibrary();

        const window = try checkSDLPtr(c.SDL_Window, c.SDL_CreateWindow(
            title,
            @intCast(width),
            @intCast(height),
            c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIDDEN,
        ));
        errdefer c.SDL_DestroyWindow(window);

        // Fix: Heap allocate the GC so pointers to it remain valid after Core is moved/returned
        const gc = try allocator.create(GraphicsContext);
        errdefer allocator.destroy(gc);

        gc.* = try GraphicsContext.init(allocator, title, window);
        errdefer gc.deinit();

        var swapchain = try Swapchain.init(gc, allocator, .{ .width = width, .height = height });
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

        const depth_texture = try Texture.init(gc, .{ .width = swapchain.extent.width, .height = swapchain.extent.height, .depth = 1 }, .d32_sfloat, .{ .depth_stencil_attachment_bit = true }, .{
            .device_local_bit = true,
        });
        errdefer depth_texture.deinit(gc);

        try checkSDL(c.SDL_ShowWindow(window));

        return Core{
            .allocator = allocator,
            .window = window,
            .gc = gc,
            .swapchain = swapchain,
            .depth_texture = depth_texture,
            .command_pool = command_pool,
            .cmdbufs = cmdbufs,
        };
    }

    pub fn deinit(self: *Core) void {
        self.gc.dev.deviceWaitIdle() catch {};
        self.depth_texture.deinit(self.gc);
        self.gc.dev.freeCommandBuffers(self.command_pool, @intCast(self.cmdbufs.len), self.cmdbufs.ptr);
        self.gc.dev.destroyCommandPool(self.command_pool, null);
        self.allocator.free(self.cmdbufs);
        self.swapchain.deinit();

        // Cleanup heap-allocated GC
        self.gc.deinit();
        self.allocator.destroy(self.gc);

        c.SDL_DestroyWindow(self.window);
        c.SDL_Vulkan_UnloadLibrary();
        c.SDL_Quit();
    }

    pub fn beginFrame(self: *Core) !?vk.CommandBuffer {
        var w: c_int = undefined;
        var h: c_int = undefined;
        try checkSDL(c.SDL_GetWindowSizeInPixels(self.window, &w, &h));

        if (w == 0 or h == 0) return null;

        if (self.resizing or self.swapchain.extent.width != @as(u32, @intCast(w)) or self.swapchain.extent.height != @as(u32, @intCast(h))) {
            try self.recreate(@intCast(w), @intCast(h));
            self.resizing = false;
        }

        const current = self.swapchain.currentSwapImage();
        try current.waitForFence(self.gc);
        try self.gc.dev.resetFences(1, @ptrCast(&current.frame_fence));

        const cmdbuf = self.cmdbufs[self.swapchain.image_index];
        try self.gc.dev.resetCommandBuffer(cmdbuf, .{});

        return cmdbuf;
    }

    pub fn endFrame(self: *Core, cmdbuf: vk.CommandBuffer) !void {
        _ = self.swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.resizing = true;
            },
            else => return err,
        };
    }

    fn recreate(self: *Core, w: u32, h: u32) !void {
        try self.gc.dev.deviceWaitIdle();
        try self.swapchain.recreate(.{ .width = w, .height = h });

        self.depth_texture.deinit(self.gc);
        self.depth_texture = try Texture.init(self.gc, .{ .width = w, .height = h, .depth = 1 }, .d32_sfloat, .{ .depth_stencil_attachment_bit = true }, .{
            .device_local_bit = true,
        });
    }

    fn errorSDL() !void {
        std.log.err("SDL Error: {s}", .{c.SDL_GetError()});
        return error.SDL;
    }

    fn checkSDL(ret: bool) !void {
        if (!ret) try errorSDL();
    }

    fn checkSDLPtr(comptime T: type, ptr: ?*T) !*T {
        if (ptr) |p| return p else {
            try errorSDL();
            unreachable;
        }
    }
};
