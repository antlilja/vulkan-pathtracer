#ifndef COMMON_GLSL
#define COMMON_GLSL

struct Payload {
    uint primitive_index;
    uint triangle_index;
    float t;
    vec2 barycentric;
    mat4x3 object_to_world;
    mat4x3 world_to_object;
};

#endif
