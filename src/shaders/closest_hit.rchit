#version 460
#extension GL_GOOGLE_include_directive: require
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_nonuniform_qualifier : enable
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int16 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int32 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

#include "rand.glsl"
#include "common.glsl"

#define MATERIAL_INDEX_MASK 0xFFFFFF
#define UINT32_INDICES_MASK 0x80000000
struct Primitive {
    uint64_t index_address;
    uint64_t normal_address;
    uint64_t tangent_address;
    uint64_t uv_address;
    uint info;
};

#define MATERIAL_TEXTURE_INDEX_MASK 0x7FFFFFFF
#define MATERIAL_TEXTURE_EXISTS_MASK 0x80000000
struct Material {
    uint albedo;
    uint metal_roughness;
    uint normal;
    uint emissive;
};

layout(location = 0) rayPayloadInEXT Payload payload;
hitAttributeEXT vec2 attribs;

layout(constant_id = 0) const uint NUM_BOUNCES = 2;

layout(buffer_reference, scalar) readonly buffer Normals {
    vec3 v[];
};
layout(buffer_reference, scalar) readonly buffer Tangents {
    vec4 v[];
};
layout(buffer_reference, scalar) readonly buffer Uvs {
    vec2 v[];
};
layout(buffer_reference, scalar) readonly buffer Indices16 {
    uint16_t i[];
};
layout(buffer_reference, scalar) readonly buffer Indices32 {
    uint i[];
};

layout(binding = 0, set = 0) uniform accelerationStructureEXT topLevelAS;
layout(binding = 2, set = 0) readonly buffer Primitives {
    Primitive i[];
} primitives;
layout(binding = 3, set = 0) readonly buffer Materials {
    Material i[];
} materials;
layout(binding = 4, set = 0) uniform sampler2D textures[];

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
    const Primitive primitive = primitives.i[gl_InstanceCustomIndexEXT + gl_GeometryIndexEXT];

    Normals normals = Normals(primitive.normal_address);
    Tangents tangents = Tangents(primitive.tangent_address);
    Uvs uvs = Uvs(primitive.uv_address);

    uvec3 index;
    if ((primitive.info & UINT32_INDICES_MASK) == 0) {
        Indices16 indices = Indices16(primitive.index_address);
        const uint16_t index0 = indices.i[3 * gl_PrimitiveID + 0];
        const uint16_t index1 = indices.i[3 * gl_PrimitiveID + 1];
        const uint16_t index2 = indices.i[3 * gl_PrimitiveID + 2];
        index = uvec3(index0, index1, index2);
    } else {
        Indices32 indices = Indices32(primitive.index_address);
        const uint index0 = indices.i[3 * gl_PrimitiveID + 0];
        const uint index1 = indices.i[3 * gl_PrimitiveID + 1];
        const uint index2 = indices.i[3 * gl_PrimitiveID + 2];
        index = uvec3(index0, index1, index2);
    }

    const vec2 uv0 = uvs.v[index.x];
    const vec2 uv1 = uvs.v[index.y];
    const vec2 uv2 = uvs.v[index.z];
    const vec2 uv = vec2(uv0 * coords.x + uv1 * coords.y + uv2 * coords.z);

    const Material material = materials.i[primitive.info & MATERIAL_INDEX_MASK];

    vec3 emissive;
    if ((material.emissive & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
        emissive = texture(textures[material.emissive & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
    } else {
        emissive = unpackUnorm4x8(material.emissive).rgb;
    }

    vec3 albedo;
    if ((material.albedo & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
        albedo = texture(textures[material.albedo & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
    } else {
        albedo = unpackUnorm4x8(material.albedo).rgb;
    }

    payload.color += emissive * 10.0 * payload.atten;
    payload.atten *= albedo * 0.5;

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

        float roughness;
        if ((material.metal_roughness & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
            const vec3 metal_roughness = texture(textures[material.metal_roughness & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
            roughness = metal_roughness.g;
        } else {
            const vec3 metal_roughness = unpackUnorm4x8(material.metal_roughness).rgb;
            roughness = metal_roughness.g;
        }

        vec3 normal;
        if ((material.normal & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
            const mat3 TBN = mat3(
                    surface_tangent,
                    surface_bitangent,
                    surface_normal
                ) * mat3(gl_ObjectToWorldEXT);
            normal = normalize(TBN * normalize(2.0 * texture(textures[material.normal & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb - vec3(1.0)));
        } else {
            normal = surface_normal * mat3(gl_ObjectToWorldEXT);
        }

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
