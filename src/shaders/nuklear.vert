#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in uvec4 inColor;

layout(location = 0) out vec2 outUV;
layout(location = 1) out vec4 outColor;

layout(push_constant) uniform PushConstants {
    mat4 proj;
} pcs;

void main() {
    gl_Position = pcs.proj * vec4(inPos, 0.0, 1.0);
    gl_Position.y = -gl_Position.y;
    outColor = vec4(inColor[0] / 255.0, inColor[1] / 255.0, inColor[2] / 255.0, inColor[3] / 255.0);
    outUV = inUV;
}
