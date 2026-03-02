// skybox.vert
#version 450
layout(location = 0) out vec3 fragDir;

layout(push_constant) uniform PC {
    mat4 proj;
    mat4 view;
} pc;

void main() {
    // Fullscreen triangle, no VBO
    vec2 pos = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    gl_Position = vec4(pos, 1.0, 1.0); // z=1.0 = far plane

    mat4 invVP = inverse(pc.proj * pc.view);
    vec4 world = invVP * vec4(pos, 1.0, 1.0);
    fragDir = normalize(world.xyz / world.w);
}