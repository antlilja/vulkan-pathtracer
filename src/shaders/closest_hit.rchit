#version 460
#extension GL_GOOGLE_include_directive: require
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_nonuniform_qualifier : enable
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int32 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

#include "rand.glsl"

struct Primitive {
    uint64_t index_address;
    uint64_t normal_address;
    uint64_t tangent_address;
    uint64_t uv_address;
    uint material_index;
};

struct Material {
    uint albedo;
    uint metal_roughness;
    uint normal;
    uint emissive;
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

    Indices indices = Indices(primitive.index_address);
    Normals normals = Normals(primitive.normal_address);
    Tangents tangents = Tangents(primitive.tangent_address);
    Uvs uvs = Uvs(primitive.uv_address);

    const uvec3 index = uvec3(indices.i[3 * gl_PrimitiveID], indices.i[3 * gl_PrimitiveID + 1], indices.i[3 * gl_PrimitiveID + 2]);

    const vec2 uv0 = uvs.v[index.x];
    const vec2 uv1 = uvs.v[index.y];
    const vec2 uv2 = uvs.v[index.z];
    const vec2 uv = vec2(uv0 * coords.x + uv1 * coords.y + uv2 * coords.z);

    const Material material = materials.i[primitive.material_index];

    vec3 emissive;
    if ((material.emissive & 0x80000000) != 0) {
        emissive = texture(textures[material.emissive & 0x7FFFFFFF], uv).rgb;
    } else {
        emissive = unpackUnorm4x8(material.emissive).rgb;
    }

    vec3 albedo;
    if ((material.albedo & 0x80000000) != 0) {
        albedo = texture(textures[material.albedo & 0x7FFFFFFF], uv).rgb;
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
        if ((material.metal_roughness & 0x80000000) != 0) {
            const vec3 metal_roughness = texture(textures[material.metal_roughness & 0x7FFFFFFF], uv).rgb;
            roughness = metal_roughness.g;
        } else {
            const vec3 metal_roughness = unpackUnorm4x8(material.metal_roughness).rgb;
            roughness = metal_roughness.g;
        }

        vec3 normal;
        if ((material.normal & 0x80000000) != 0) {
            const mat3 TBN = mat3(
                    surface_tangent,
                    surface_bitangent,
                    surface_normal
                ) * mat3(gl_ObjectToWorldEXT);
            normal = normalize(TBN * normalize(2.0 * texture(textures[material.normal & 0x7FFFFFFF], uv).rgb - vec3(1.0)));
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
