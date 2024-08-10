#ifndef MATERIAL_GLSL
#define MATERIAL_GLSL

#define MATERIAL_TEXTURE_INDEX_MASK 0x7FFFFFFF
#define MATERIAL_TEXTURE_EXISTS_MASK 0x80000000
struct Material {
    uint albedo;
    uint metal_roughness;
    uint normal;
    uint emissive;
};

struct MaterialData {
    vec3 albedo;
    vec3 normal;
    vec3 emissive;
    float roughness;
};

layout(binding = 3, set = 0) readonly buffer Materials {
    Material i[];
} materials;
layout(binding = 4, set = 0) uniform sampler2D textures[];

MaterialData getMaterialData(uint material_index, vec2 uv) {
    MaterialData material_data;

    const Material material = materials.i[material_index];

    if ((material.albedo & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
        material_data.albedo = texture(textures[material.albedo & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
    } else {
        material_data.albedo = unpackUnorm4x8(material.albedo).rgb;
    }

    if ((material.normal & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
        material_data.normal = texture(textures[material.normal & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
    } else {
        material_data.normal = vec3(0.19607843137, 0.19607843137, 0.39215686274);
    }

    if ((material.emissive & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
        material_data.emissive = texture(textures[material.emissive & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
    } else {
        material_data.emissive = unpackUnorm4x8(material.emissive).rgb;
    }

    float roughness;
    if ((material.metal_roughness & MATERIAL_TEXTURE_EXISTS_MASK) != 0) {
        const vec3 metal_roughness = texture(textures[material.metal_roughness & MATERIAL_TEXTURE_INDEX_MASK], uv).rgb;
        material_data.roughness = metal_roughness.g;
    } else {
        const vec3 metal_roughness = unpackUnorm4x8(material.metal_roughness).rgb;
        material_data.roughness = metal_roughness.g;
    }

    return material_data;
}

#endif
