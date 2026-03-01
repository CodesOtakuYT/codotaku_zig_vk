#version 450

layout(location = 0) in vec2 v_uv;

layout(location = 0) out vec4 f_color;

// Binding 1 for the combined image sampler
layout(set = 0, binding = 1) uniform sampler2D texSampler;

void main() {
    // Sample the texture at the given UV coordinate
    f_color = texture(texSampler, v_uv);
}