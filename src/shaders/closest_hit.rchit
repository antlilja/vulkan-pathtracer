#version 460
#extension GL_GOOGLE_include_directive: require
#extension GL_EXT_ray_tracing : require

#include "common.glsl"

layout(location = 0) rayPayloadInEXT Payload payload;
hitAttributeEXT vec2 attribs;

void main() {
    payload.primitive_index = gl_InstanceCustomIndexEXT + gl_GeometryIndexEXT;
    payload.triangle_index = gl_PrimitiveID;
    payload.t = gl_HitTEXT;
    payload.barycentric = attribs;
    payload.object_to_world = gl_ObjectToWorldEXT;
    payload.world_to_object = gl_WorldToObjectEXT;
}
