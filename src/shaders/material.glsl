#ifndef MATERIAL_GLSL
#define MATERIAL_GLSL

#include "triangle.glsl"

#define MATERIAL_INVALID_TEXTURE_INDEX 0xFFFFFFFF
struct Material {
    uint albedo_factor;
    uint metal_roughness_factor;
    uint emissive_factor;

    uint albedo_texture_index;
    uint metal_roughness_texture_index;
    uint emissive_texture_index;
    uint normal_texture_index;
};

struct MaterialData {
    vec4 albedo;
    vec3 normal;
    vec3 emissive;
    float roughness;
    float metallic;
};

layout(binding = 3, set = 0) readonly buffer Materials {
    Material i[];
} materials;
layout(binding = 4, set = 0) uniform sampler2D textures[];

MaterialData getMaterialData(TriangleData triangle_data) {
    MaterialData material_data;

    const Material material = materials.i[triangle_data.material_index];

    material_data.albedo = unpackUnorm4x8(material.albedo_factor);
    if (material.albedo_texture_index != MATERIAL_INVALID_TEXTURE_INDEX) {
        material_data.albedo *= texture(textures[material.albedo_texture_index], triangle_data.uv);
    }

    const vec4 metal_roughness_factor = unpackUnorm4x8(material.metal_roughness_factor);
    material_data.roughness = metal_roughness_factor.g;
    material_data.metallic = metal_roughness_factor.b;
    if (material.metal_roughness_texture_index != MATERIAL_INVALID_TEXTURE_INDEX) {
        const vec4 metal_roughness = texture(textures[material.metal_roughness_texture_index], triangle_data.uv);
        material_data.roughness *= metal_roughness.g;
        material_data.metallic *= metal_roughness.b;
    }

    material_data.emissive = unpackUnorm4x8(material.emissive_factor).rgb;
    if (material.emissive_texture_index != MATERIAL_INVALID_TEXTURE_INDEX) {
        material_data.emissive *= texture(textures[material.emissive_texture_index], triangle_data.uv).rgb;
    }

    material_data.normal = triangle_data.normal;
    if (material.normal_texture_index != MATERIAL_INVALID_TEXTURE_INDEX) {
        const vec3 normal_tangent_space = texture(textures[material.normal_texture_index], triangle_data.uv).rgb;

        const vec3 bitangent = cross(triangle_data.normal, triangle_data.tangent.xyz) * triangle_data.tangent.w;
        const mat3 tangent_to_world = mat3(
                triangle_data.tangent.xyz,
                bitangent,
                triangle_data.normal
            );
        material_data.normal = tangent_to_world * normalize(2.0 * normal_tangent_space - vec3(1.0));
    }

    return material_data;
}

#endif
