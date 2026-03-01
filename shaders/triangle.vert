#version 450

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;

layout(location = 0) out vec2 v_uv;

layout(set = 0, binding = 0) uniform Camera {
    mat4 mvp;
} camera;

void main() {
    gl_Position = camera.mvp * vec4(a_pos, 1.0);
    v_uv = a_uv;
}