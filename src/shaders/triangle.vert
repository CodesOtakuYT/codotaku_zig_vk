#version 450

struct Vertex {
    vec2 pos;
    vec3 color;
};

const Vertex vertices[] = Vertex[](
    Vertex(vec2( 0.0, -0.5), vec3(1.0, 0.0, 0.0)),
    Vertex(vec2( 0.5,  0.5), vec3(0.0, 1.0, 0.0)),
    Vertex(vec2(-0.5,  0.5), vec3(0.0, 0.0, 1.0))
);

layout(location = 0) out vec3 v_color;

void main() {
    Vertex v = vertices[gl_VertexIndex];
    gl_Position = vec4(v.pos, 0.0, 1.0);
    v_color = v.color;
}