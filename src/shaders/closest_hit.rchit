#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_nonuniform_qualifier : enable
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int32 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

#include "rand.glsl"

struct ObjDesc {
    uint64_t index_address;
    uint64_t normal_address;
    uint64_t tangent_address;
    uint64_t uv_address;
    uint64_t material_address;
};

struct Payload {
    vec3 color;
    vec3 atten;
    uint rng_state;
    uint depth;
};

layout(location = 0) rayPayloadInEXT Payload payload;
hitAttributeEXT vec2 attribs;

layout(constant_id = 0) const uint NUM_BOUNCES = 2;

layout(buffer_reference, scalar) readonly buffer Normals {
    vec4 v[];
};
layout(buffer_reference, scalar) readonly buffer Tangents {
    vec4 v[];
};
layout(buffer_reference, scalar) readonly buffer Uvs {
    vec2 v[];
};
layout(buffer_reference, scalar) readonly buffer Indices {
    uint i[];
};
layout(buffer_reference, scalar) readonly buffer Materials {
    uint i[];
};

layout(binding = 0, set = 0) uniform accelerationStructureEXT topLevelAS;
layout(binding = 2, set = 0) readonly buffer ObjDescs {
    ObjDesc i[];
} obj_descs;
layout(binding = 3, set = 0) uniform sampler2D albedos[];
layout(binding = 4, set = 0) uniform sampler2D metal_roughness[];
layout(binding = 5, set = 0) uniform sampler2D emissives[];
layout(binding = 6, set = 0) uniform sampler2D normal_textures[];

mat3 normalMatrix(vec3 normal) {
    vec3 orthogonal;
    if (abs(normal.x) > 0.99) {
        orthogonal = vec3(0, 0, 1);
    } else {
        orthogonal = vec3(1, 0, 0);
    }

    const vec3 tangent = normalize(cross(normal, orthogonal));
    const vec3 bitangent = normalize(cross(normal, tangent));
    return mat3(tangent, bitangent, normal);
}

void main() {
    const vec3 coords = vec3(1.0f - attribs.x - attribs.y, attribs.x, attribs.y);
    const ObjDesc obj_desc = obj_descs.i[gl_InstanceCustomIndexEXT];

    Indices indices = Indices(obj_desc.index_address);
    Normals normals = Normals(obj_desc.normal_address);
    Tangents tangents = Tangents(obj_desc.tangent_address);
    Uvs uvs = Uvs(obj_desc.uv_address);
    Materials materials = Materials(obj_desc.material_address);

    const uvec3 index = uvec3(indices.i[3 * gl_PrimitiveID], indices.i[3 * gl_PrimitiveID + 1], indices.i[3 * gl_PrimitiveID + 2]);

    const vec2 uv0 = uvs.v[index.x];
    const vec2 uv1 = uvs.v[index.y];
    const vec2 uv2 = uvs.v[index.z];
    const vec2 uv = vec2(uv0 * coords.x + uv1 * coords.y + uv2 * coords.z);

    const uint material_id = materials.i[gl_PrimitiveID];

    payload.color += texture(emissives[material_id], uv).xyz * 10.0 * payload.atten;
    payload.atten *= texture(albedos[material_id], uv).xyz * 0.5;

    if (payload.depth < NUM_BOUNCES) {
        const vec3 n0 = normals.v[index.x].xyz;
        const vec3 n1 = normals.v[index.y].xyz;
        const vec3 n2 = normals.v[index.z].xyz;

        const vec3 surface_normal = normalize(n0 * coords.x + n1 * coords.y + n2 * coords.z);

        const vec4 t0 = tangents.v[index.x];
        const vec4 t1 = tangents.v[index.y];
        const vec4 t2 = tangents.v[index.z];

        const vec4 surface_tangent_4 = normalize(t0 * coords.x + t1 * coords.y + t2 * coords.z);
        const vec3 surface_tangent = surface_tangent_4.xyz * surface_tangent_4.w;

        const vec3 surface_bitangent = normalize(cross(surface_normal, surface_tangent));

        const mat3 TBN = mat3(
                surface_tangent,
                surface_bitangent,
                surface_normal
            ) * mat3(gl_ObjectToWorldEXT);

        const vec3 metal_roughness = texture(metal_roughness[material_id], uv).xyz;
        const float roughness = metal_roughness.y;

        const vec3 normal_texture = normalize(2.0 * texture(normal_textures[material_id], uv).rgb - vec3(1.0));
        const vec3 normal = normalize(TBN * normal_texture);

        const float tmin = 0.001;
        const float tmax = 10000.0;
        const vec3 origin = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT + (surface_normal * mat3(gl_ObjectToWorldEXT)) * 0.01f;
        const vec3 diffuse = cosine_weighted_sample(payload.rng_state, normalMatrix(normal));
        const vec3 reflection = reflect(gl_WorldRayDirectionEXT, normal);
        const vec3 direction = normalize(mix(reflection, diffuse, roughness));

        payload.depth += 1;
        traceRayEXT(topLevelAS,
            gl_RayFlagsOpaqueEXT | gl_RayFlagsCullBackFacingTrianglesEXT,
            0xff,
            0,
            0,
            0,
            origin,
            tmin,
            direction,
            tmax,
            0
        );
    }
}
