#ifndef TRIANGLE_GLSL
#define TRIANGLE_GLSL

#define MATERIAL_INDEX_MASK 0xFFFFFF
#define UINT32_INDICES_MASK 0x80000000
struct Primitive {
    uint64_t index_address;
    uint64_t position_address;
    uint64_t normal_address;
    uint64_t tangent_address;
    uint64_t uv_address;
    uint info;
};

struct TriangleData {
    vec2 uv;
    vec3 normal;
    vec4 tangent;
    vec3 geometry_normal;
    uint material_index;
};

layout(buffer_reference, scalar) readonly buffer Positions {
    vec3 v[];
};
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

layout(binding = 2, set = 0) readonly buffer Primitives {
    Primitive i[];
} primitives;

TriangleData getTriangleData(Payload payload) {
    TriangleData triangle_data;

    const Primitive primitive = primitives.i[payload.primitive_index];
    const vec3 coords = vec3(
            1.0f - payload.barycentric.x - payload.barycentric.y,
            payload.barycentric.x,
            payload.barycentric.y
        );

    uvec3 index;
    if ((primitive.info & UINT32_INDICES_MASK) == 0) {
        Indices16 indices = Indices16(primitive.index_address);
        const uint16_t index0 = indices.i[3 * payload.triangle_index + 0];
        const uint16_t index1 = indices.i[3 * payload.triangle_index + 1];
        const uint16_t index2 = indices.i[3 * payload.triangle_index + 2];
        index = uvec3(index0, index1, index2);
    } else {
        Indices32 indices = Indices32(primitive.index_address);
        const uint index0 = indices.i[3 * payload.triangle_index + 0];
        const uint index1 = indices.i[3 * payload.triangle_index + 1];
        const uint index2 = indices.i[3 * payload.triangle_index + 2];
        index = uvec3(index0, index1, index2);
    }

    {
        Uvs uvs = Uvs(primitive.uv_address);
        const vec2 uv0 = uvs.v[index.x];
        const vec2 uv1 = uvs.v[index.y];
        const vec2 uv2 = uvs.v[index.z];
        triangle_data.uv = vec2(uv0 * coords.x + uv1 * coords.y + uv2 * coords.z);
    }

    const mat3 normal_world_matrix = transpose(inverse(mat3(payload.object_to_world)));
    {
        Normals normals = Normals(primitive.normal_address);
        const vec3 n0 = normals.v[index.x].xyz;
        const vec3 n1 = normals.v[index.y].xyz;
        const vec3 n2 = normals.v[index.z].xyz;
        const vec3 normal = n0 * coords.x + n1 * coords.y + n2 * coords.z;
        triangle_data.normal = normalize(normal * normal_world_matrix);
    }

    {
        Tangents tangents = Tangents(primitive.tangent_address);
        const vec4 t0 = tangents.v[index.x];
        const vec4 t1 = tangents.v[index.y];
        const vec4 t2 = tangents.v[index.z];
        const vec4 tangent = t0 * coords.x + t1 * coords.y + t2 * coords.z;
        triangle_data.tangent.xyz = normalize(tangent.xyz * normal_world_matrix);
        triangle_data.tangent.w = tangent.w;
    }

    {
        Positions positions = Positions(primitive.position_address);
        triangle_data.geometry_normal = normalize(
                cross(
                    positions.v[index.y] - positions.v[index.x],
                    positions.v[index.z] - positions.v[index.x]
                ) * normal_world_matrix
            );
    }

    triangle_data.material_index = primitive.info & MATERIAL_INDEX_MASK;

    return triangle_data;
}

#endif
