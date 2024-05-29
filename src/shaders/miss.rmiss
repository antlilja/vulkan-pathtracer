#version 460
#extension GL_EXT_ray_tracing : enable
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_explicit_arithmetic_types_int32 : require

struct Payload {
    vec3 color;
    vec3 atten;
    uint rng_state;
    uint depth;
};

layout(location = 0) rayPayloadInEXT Payload payload;

void main() {
    float t = 0.5 * (gl_WorldRayDirectionEXT.y + 1.0);
    vec3 white = vec3(1.0, 1.0, 1.0);
    vec3 blue = vec3(0.5, 0.7, 1.0);
    payload.color += payload.atten * mix(white, blue, t);
}
