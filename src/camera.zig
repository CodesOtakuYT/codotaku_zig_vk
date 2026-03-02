const std = @import("std");
const vk = @import("vulkan");
const za = @import("zalgebra");
const Mat4 = za.Mat4;
const Vec3 = za.Vec3;
const Quat = za.Quat;
const c = @import("c.zig").c;

const Self = @This();

// --- Core State ---
eye: Vec3,
target: Vec3,
up: Vec3,
// We track Euler angles for FPS stability; Quaternions without roll
// tend to "drift" or tilt slightly over time due to float precision.
yaw: f32 = -90.0,
pitch: f32 = 0.0,

// --- Config ---
fov: f32 = 45.0,
near: f32 = 0.1,
far: f32 = 100.0,
mouse_sensitivity: f32 = 0.1,
move_speed: f32 = 5.0,

// --- Input Tracking ---
is_captured: bool = false,
/// x: Right/Left, y: Up/Down, z: Forward/Backward
input_dir: Vec3 = Vec3.zero(),

pub fn init(eye: Vec3, target: Vec3, up: Vec3) Self {
    return .{
        .eye = eye,
        .target = target,
        .up = up,
    };
}

pub fn getDescriptorMatrix(self: Self, extent: vk.Extent2D) Mat4 {
    const aspect = @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));
    var projection = za.perspective(self.fov, aspect, self.near, self.far);

    // Vulkan Clip Space Y-axis points down
    projection.data[1][1] *= -1;

    const view = za.lookAt(self.eye, self.target, self.up);
    return projection.mul(view);
}

pub fn onEvent(self: *Self, event: c.SDL_Event, window: ?*c.SDL_Window) void {
    switch (event.type) {
        // --- Hold to Look ---
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (event.button.button == c.SDL_BUTTON_RIGHT) {
                self.is_captured = true;
                if (window) |w| _ = c.SDL_SetWindowRelativeMouseMode(w, true);
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.button == c.SDL_BUTTON_RIGHT) {
                self.is_captured = false;
                if (window) |w| _ = c.SDL_SetWindowRelativeMouseMode(w, false);
            }
        },

        // --- Mouse Rotation (Standard FPS) ---
        c.SDL_EVENT_MOUSE_MOTION => {
            if (self.is_captured) {
                self.yaw += event.motion.xrel * self.mouse_sensitivity;
                self.pitch -= event.motion.yrel * self.mouse_sensitivity;

                // Clamp pitch to prevent the "flipping" camera bug
                self.pitch = std.math.clamp(self.pitch, -89.0, 89.0);
            }
        },

        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            const is_down = event.type == c.SDL_EVENT_KEY_DOWN;
            const val: f32 = if (is_down) 1.0 else 0.0;
            const neg_val: f32 = if (is_down) -1.0 else 0.0;

            switch (event.key.key) {
                c.SDLK_W => self.input_dir.zMut().* = val,
                c.SDLK_S => self.input_dir.zMut().* = neg_val,
                c.SDLK_D => self.input_dir.xMut().* = val,
                c.SDLK_A => self.input_dir.xMut().* = neg_val,
                c.SDLK_SPACE => self.input_dir.yMut().* = val,
                c.SDLK_LCTRL => self.input_dir.yMut().* = neg_val,
                else => {},
            }
        },
        else => {},
    }
}

pub fn update(self: *Self, dt: f32) void {
    // 1. Calculate Forward vector from Yaw/Pitch
    const yaw_rad = za.toRadians(self.yaw);
    const pitch_rad = za.toRadians(self.pitch);

    const forward = Vec3.new(
        @cos(yaw_rad) * @cos(pitch_rad),
        @sin(pitch_rad),
        @sin(yaw_rad) * @cos(pitch_rad),
    ).norm();

    // 2. Derive Right and Up vectors (Fixed to World Up)
    const world_up = Vec3.new(0, 1, 0);
    const right = Vec3.cross(forward, world_up).norm();
    const actual_up = Vec3.cross(right, forward).norm();

    // 3. Handle Movement
    var wish_dir = Vec3.zero();
    // Forward/Back (W/S)
    if (self.input_dir.z() != 0) wish_dir = wish_dir.add(forward.scale(self.input_dir.z()));
    // Right/Left (D/A)
    if (self.input_dir.x() != 0) wish_dir = wish_dir.add(right.scale(self.input_dir.x()));
    // Up/Down (Space/LCTRL)
    if (self.input_dir.y() != 0) wish_dir = wish_dir.add(actual_up.scale(self.input_dir.y()));

    if (wish_dir.lengthSq() > 0) {
        const displacement = wish_dir.norm().scale(self.move_speed * dt);
        self.eye = self.eye.add(displacement);
    }

    // 4. Update Final State
    self.target = self.eye.add(forward);
    self.up = actual_up;
}
