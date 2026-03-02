#version 450
layout(location = 0) out vec3 fragDir;

layout(push_constant) uniform PC {
    mat4 proj;
    mat4 view; // This must have translation stripped in Zig!
} pc;

void main() {
    // Fullscreen triangle
    vec2 pos = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2) * 2.0 - 1.0;
    gl_Position = vec4(pos, 1.0, 1.0); 

    // 1. Un-project from clip space to view space
    // We use the inverse projection to find where the ray points in "camera space"
    vec4 rayView = inverse(pc.proj) * vec4(pos, 1.0, 1.0);
    
    // 2. Transform that ray into world space
    // We only care about rotation, so we use the inverse view matrix
    // If you stripped translation in Zig, pc.view is just rotation.
    fragDir = (inverse(pc.view) * vec4(rayView.xyz, 0.0)).xyz;
}