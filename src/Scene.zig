const std = @import("std");
const vk = @import("vulkan");

const Mat4 = @import("Mat4.zig");

const c = @cImport({
    @cInclude("cgltf.h");
});

const zi = @import("zigimg");

const Self = @This();

pub const Instance = struct {
    mesh_index: usize,
    transform: Mat4,
};

pub const Mesh = struct {
    start: u32,
    end: u32,
};

pub const Primitive = struct {
    indices_offset: usize,
    positions_offset: usize,
    normals_offset: usize,
    tangents_offset: usize,
    uvs_offset: usize,
    max_vertex: u32,
    triangle_count: u32,
    info: packed struct(u32) {
        material_index: u24,
        reserved: u7 = 0,
        uint32_indices: bool,
    },
};

pub const Material = struct {
    albedo: u32,
    metal_roughness: u32,
    normal: u32,
    emissive: u32,
};

pub const Texture = struct {
    data: []const u8,
    width: u32,
    height: u32,
};

arena: std.heap.ArenaAllocator,

instances: []const Instance,
meshes: []const Mesh,
primitives: []const Primitive,
triangle_data: []const u8,

materials: []const Material,

textures: []const Texture,

pub fn load(path: []const u8, allocator: std.mem.Allocator) !Self {
    const gltf_data = blk: {
        const path_c = try allocator.dupeZ(u8, path);
        defer allocator.free(path_c);

        const options = c.cgltf_options{};
        var gltf_data: *c.cgltf_data = undefined;
        if (c.cgltf_parse_file(&options, path_c, @ptrCast(&gltf_data)) != c.cgltf_result_success) return error.FailedToLoadGLTF;
        errdefer c.cgltf_free(@ptrCast(gltf_data));

        if (c.cgltf_load_buffers(
            &options,
            @ptrCast(gltf_data),
            path_c,
        ) != c.cgltf_result_success) return error.FailedToLoadGLTF;
        if (c.cgltf_validate(@ptrCast(gltf_data)) != c.cgltf_result_success) return error.FailedToLoadGLTF;

        break :blk gltf_data;
    };
    defer c.cgltf_free(@ptrCast(gltf_data));

    var self: Self = undefined;
    self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer self.arena.deinit();

    try self.loadMeshes(gltf_data);

    try self.loadTextures(gltf_data, std.fs.cwd(), allocator);

    try self.loadMaterials(gltf_data);

    try self.loadScene(gltf_data, allocator);

    return self;
}

pub fn deinit(self: *const Self) void {
    self.arena.deinit();
}

fn loadMeshes(
    self: *Self,
    gltf_data: *const c.cgltf_data,
) !void {
    const arena_allocator = self.arena.allocator();

    if (gltf_data.buffers_count != 1) return error.FailedToLoadGLTF;

    const meshes = try arena_allocator.alloc(Mesh, gltf_data.meshes_count);

    const primitives, const triangle_data, const indices_offset, const positions_offset, const normals_offset, const tangents_offset, const uvs_offset = blk: {
        var primitives_count: usize = 0;
        var indices_size: usize = 0;
        var positions_size: usize = 0;
        var normals_size: usize = 0;
        var tangents_size: usize = 0;
        var uvs_size: usize = 0;
        for (
            gltf_data.meshes[0..gltf_data.meshes_count],
            meshes,
        ) |
            gltf_mesh,
            *mesh,
        | {
            const primitives_start = primitives_count;
            primitives_count += gltf_mesh.primitives_count;

            mesh.* = .{
                .start = @intCast(primitives_start),
                .end = @intCast(primitives_count),
            };

            for (gltf_mesh.primitives[0..gltf_mesh.primitives_count]) |gltf_primitive| {
                if (gltf_primitive.type != c.cgltf_primitive_type_triangles) return error.GLTFNotTriangles;

                var positions_acc: ?*c.cgltf_accessor = null;
                var normals_acc: ?*c.cgltf_accessor = null;
                var tangents_acc: ?*c.cgltf_accessor = null;
                var uvs_acc: ?*c.cgltf_accessor = null;

                for (gltf_primitive.attributes[0..gltf_primitive.attributes_count]) |attr| {
                    switch (attr.type) {
                        c.cgltf_attribute_type_position => positions_acc = attr.data,
                        c.cgltf_attribute_type_normal => normals_acc = attr.data,
                        c.cgltf_attribute_type_tangent => tangents_acc = attr.data,
                        c.cgltf_attribute_type_texcoord => {
                            if (uvs_acc == null) uvs_acc = attr.data;
                        },
                        else => {},
                    }
                }

                if (gltf_primitive.indices) |acc| {
                    indices_size = std.mem.alignForward(usize, indices_size, acc.*.stride);
                    indices_size += acc.*.count * acc.*.stride;
                } else return error.GLTFNoIndices;

                if (positions_acc) |acc| {
                    positions_size += acc.count * acc.stride;
                } else return error.GLTFNoPositions;

                if (normals_acc) |acc| {
                    normals_size += acc.count * @sizeOf([4]f32);
                } else return error.GLTFNoNormals;

                if (tangents_acc) |acc| {
                    tangents_size += acc.count * @sizeOf([4]f32);
                } else return error.GLTFNoTangents;

                if (uvs_acc) |acc| {
                    uvs_size += acc.count * acc.stride;
                } else return error.GLTFNoUVs;
            }
        }

        indices_size = std.mem.alignForward(usize, indices_size, @sizeOf([4]f32));
        positions_size = std.mem.alignForward(usize, positions_size, @sizeOf([4]f32));
        normals_size = std.mem.alignForward(usize, normals_size, @sizeOf([4]f32));
        tangents_size = std.mem.alignForward(usize, tangents_size, @sizeOf([4]f32));
        uvs_size = std.mem.alignForward(usize, uvs_size, @sizeOf([4]f32));

        const size =
            indices_size +
            positions_size +
            normals_size +
            tangents_size +
            uvs_size;

        break :blk .{
            try arena_allocator.alloc(Primitive, primitives_count),
            try arena_allocator.alloc(u8, size),
            0,
            indices_size,
            indices_size + positions_size,
            indices_size + positions_size + normals_size,
            indices_size + positions_size + normals_size + tangents_size,
        };
    };

    {
        var indices_index: usize = indices_offset;
        var positions_index: usize = positions_offset;
        var normals_index: usize = normals_offset;
        var tangents_index: usize = tangents_offset;
        var uvs_index: usize = uvs_offset;
        for (
            gltf_data.meshes[0..gltf_data.meshes_count],
            meshes,
        ) |gltf_mesh, *mesh| {
            for (
                gltf_mesh.primitives[0..gltf_mesh.primitives_count],
                primitives[mesh.start..mesh.end],
            ) |
                gltf_primitive,
                *primitive,
            | {
                var positions_acc: *c.cgltf_accessor = undefined;
                var normals_acc: *c.cgltf_accessor = undefined;
                var tangents_acc: *c.cgltf_accessor = undefined;
                var maybe_uvs_acc: ?*c.cgltf_accessor = null;

                for (gltf_primitive.attributes[0..gltf_primitive.attributes_count]) |attr| {
                    switch (attr.type) {
                        c.cgltf_attribute_type_position => positions_acc = attr.data,
                        c.cgltf_attribute_type_normal => normals_acc = attr.data,
                        c.cgltf_attribute_type_tangent => tangents_acc = attr.data,
                        c.cgltf_attribute_type_texcoord => {
                            if (maybe_uvs_acc == null) maybe_uvs_acc = attr.data;
                        },
                        else => {},
                    }
                }

                const indices_acc: *c.struct_cgltf_accessor = gltf_primitive.indices;
                const uvs_acc = maybe_uvs_acc.?;

                indices_index = std.mem.alignForward(usize, indices_index, indices_acc.stride);

                primitive.* = .{
                    .indices_offset = indices_index,
                    .positions_offset = positions_index,
                    .normals_offset = normals_index,
                    .tangents_offset = tangents_index,
                    .uvs_offset = uvs_index,
                    .max_vertex = @intCast(positions_acc.count),
                    .triangle_count = @intCast(gltf_primitive.indices.*.count / 3),
                    .info = .{
                        .material_index = @intCast((@intFromPtr(gltf_primitive.material) -
                            @intFromPtr(gltf_data.materials)) / @sizeOf(c.cgltf_material)),
                        .uint32_indices = switch (indices_acc.stride) {
                            2 => false,
                            4 => true,
                            else => unreachable,
                        },
                    },
                };

                const indices_start = indices_index;
                indices_index += indices_acc.count * indices_acc.stride;
                {
                    const gltf_buffer: [*]const u8 = @ptrCast(indices_acc.buffer_view.*.buffer.*.data);
                    std.mem.copyForwards(
                        u8,
                        triangle_data[indices_start..indices_index],
                        gltf_buffer[(indices_acc.*.offset + indices_acc.*.buffer_view.*.offset)..][0..indices_acc.*.buffer_view.*.size],
                    );
                }

                const positions_start = positions_index;
                positions_index += positions_acc.count * positions_acc.stride;

                {
                    const gltf_buffer: [*]const u8 = @ptrCast(positions_acc.buffer_view.*.buffer.*.data);
                    std.mem.copyForwards(
                        u8,
                        triangle_data[positions_start..positions_index],
                        gltf_buffer[(positions_acc.*.offset + positions_acc.*.buffer_view.*.offset)..][0..positions_acc.*.buffer_view.*.size],
                    );
                }

                const normals_start = normals_index;
                normals_index += normals_acc.count * @sizeOf([4]f32);

                {
                    const gltf_buffer: [*]const u8 = @ptrCast(normals_acc.buffer_view.*.buffer.*.data);
                    const gltf_normals: []const [3]f32 = @alignCast(std.mem.bytesAsSlice([3]f32, gltf_buffer[(normals_acc.*.offset + normals_acc.*.buffer_view.*.offset)..][0..normals_acc.*.buffer_view.*.size]));
                    const normals: [][4]f32 = @alignCast(std.mem.bytesAsSlice([4]f32, triangle_data[normals_start..normals_index]));
                    for (gltf_normals, normals) |gltf_normal, *normal| {
                        normal.* = .{
                            gltf_normal[0],
                            gltf_normal[1],
                            gltf_normal[2],
                            0.0,
                        };
                    }
                }

                const tangents_start = tangents_index;
                tangents_index += tangents_acc.count * tangents_acc.stride;

                {
                    const gltf_buffer: [*]const u8 = @ptrCast(tangents_acc.buffer_view.*.buffer.*.data);
                    std.mem.copyForwards(
                        u8,
                        triangle_data[tangents_start..tangents_index],
                        gltf_buffer[(tangents_acc.*.offset + tangents_acc.*.buffer_view.*.offset)..][0..tangents_acc.*.buffer_view.*.size],
                    );
                }

                const uvs_start = uvs_index;
                uvs_index += uvs_acc.count * uvs_acc.stride;
                {
                    const gltf_buffer: [*]const u8 = @ptrCast(uvs_acc.buffer_view.*.buffer.*.data);
                    std.mem.copyForwards(
                        u8,
                        triangle_data[uvs_start..uvs_index],
                        gltf_buffer[(uvs_acc.*.offset + uvs_acc.*.buffer_view.*.offset)..][0..uvs_acc.*.buffer_view.*.size],
                    );
                }
            }
        }
    }

    self.triangle_data = triangle_data;
    self.primitives = primitives;
    self.meshes = meshes;
}

fn loadTextures(
    self: *Self,
    gltf_data: *const c.cgltf_data,
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
) !void {
    if (gltf_data.textures == null) {
        self.textures = &.{};
        return;
    }
    const arena_allocator = self.arena.allocator();

    const textures = try arena_allocator.alloc(Texture, gltf_data.textures_count);

    const buffer: [*]const u8 = @ptrCast(gltf_data.buffers.*.data);

    for (gltf_data.textures[0..gltf_data.textures_count], textures) |texture, *out_texture| {
        var image = if (texture.image.*.uri != null) blk: {
            var file = try dir.openFile(std.mem.span(texture.image.*.uri), .{});
            defer file.close();

            break :blk try zi.Image.fromFile(allocator, &file);
        } else if (texture.image.*.buffer_view != null) blk: {
            const image_buffer = buffer[texture.image.*.buffer_view.*.offset..][0..texture.image.*.buffer_view.*.size];

            break :blk try zi.Image.fromMemory(allocator, image_buffer);
        } else return error.NoTextureFound;
        defer image.deinit();

        const image_bytes = switch (image.pixelFormat()) {
            .rgba32 => try arena_allocator.dupe(u8, image.pixels.asConstBytes()),
            else => blk: {
                const pixels = try zi.PixelFormatConverter.convert(
                    arena_allocator,
                    &image.pixels,
                    .rgba32,
                );

                break :blk pixels.asConstBytes();
            },
        };

        out_texture.* = .{
            .data = image_bytes,
            .width = @intCast(image.width),
            .height = @intCast(image.height),
        };
    }

    self.textures = textures;
}

fn loadMaterials(
    self: *Self,
    gltf_data: *const c.cgltf_data,
) !void {
    const materials = try self.arena.allocator().alloc(Material, gltf_data.materials_count);

    for (gltf_data.materials[0..gltf_data.materials_count], materials) |material, *out_material| {
        if (material.has_pbr_metallic_roughness == 0) return error.NonPbrMaterial;
        const Color = packed struct(u32) {
            r: u8,
            g: u8,
            b: u8,
            a: u8,
        };

        const has_albedo = material.pbr_metallic_roughness.base_color_texture.texture != null;
        const has_metal_roughness = material.pbr_metallic_roughness.metallic_roughness_texture.texture != null;
        const has_normal = material.normal_texture.texture != null;
        const has_emissive = material.emissive_texture.texture != null;

        const albedo_color: Color = .{
            .r = @intFromFloat(material.pbr_metallic_roughness.base_color_factor[0] * 255.0),
            .g = @intFromFloat(material.pbr_metallic_roughness.base_color_factor[1] * 255.0),
            .b = @intFromFloat(material.pbr_metallic_roughness.base_color_factor[2] * 255.0),
            .a = 0,
        };

        const metal_roughness_color: Color = .{
            .r = 0,
            .g = @intFromFloat(material.pbr_metallic_roughness.roughness_factor * 255.0),
            .b = @intFromFloat(material.pbr_metallic_roughness.metallic_factor * 255.0),
            .a = 0,
        };

        const emissive_color: Color = .{
            .r = @intFromFloat(material.emissive_factor[0] * 255.0),
            .g = @intFromFloat(material.emissive_factor[1] * 255.0),
            .b = @intFromFloat(material.emissive_factor[2] * 255.0),
            .a = 0,
        };

        const albedo: u32 = if (material.pbr_metallic_roughness.base_color_texture.texture != null)
            @intCast((@intFromPtr(material.pbr_metallic_roughness.base_color_texture.texture) -
                @intFromPtr(gltf_data.textures)) / @sizeOf(c.cgltf_texture))
        else
            @bitCast(albedo_color);

        const metal_roughness: u32 = if (material.pbr_metallic_roughness.metallic_roughness_texture.texture != null)
            @intCast((@intFromPtr(material.pbr_metallic_roughness.metallic_roughness_texture.texture) -
                @intFromPtr(gltf_data.textures)) / @sizeOf(c.cgltf_texture))
        else
            @bitCast(metal_roughness_color);

        const normal: u32 = if (material.normal_texture.texture != null)
            @intCast((@intFromPtr(material.normal_texture.texture) -
                @intFromPtr(gltf_data.textures)) / @sizeOf(c.cgltf_texture))
        else
            0;

        const emissive: u32 = if (material.emissive_texture.texture != null)
            @intCast((@intFromPtr(material.emissive_texture.texture) -
                @intFromPtr(gltf_data.textures)) / @sizeOf(c.cgltf_texture))
        else
            @bitCast(emissive_color);

        out_material.* = .{
            .albedo = albedo | @as(u32, @intFromBool(has_albedo)) << 31,
            .metal_roughness = metal_roughness | @as(u32, @intFromBool(has_metal_roughness)) << 31,
            .normal = normal | @as(u32, @intFromBool(has_normal)) << 31,
            .emissive = emissive | @as(u32, @intFromBool(has_emissive)) << 31,
        };
    }

    self.materials = materials;
}

fn loadScene(
    self: *Self,
    gltf_data: *const c.cgltf_data,
    allocator: std.mem.Allocator,
) !void {
    var instances = std.ArrayList(Instance).init(allocator);
    defer instances.deinit();

    for (gltf_data.scene.*.nodes[0..gltf_data.scene.*.nodes_count]) |node| {
        try loadSceneImpl(
            node,
            Mat4.identity(),
            gltf_data,
            &instances,
        );
    }

    self.instances = try self.arena.allocator().dupe(Instance, instances.items);
}

fn loadSceneImpl(
    node: *c.cgltf_node,
    parent_matrix: Mat4,
    gltf_data: *const c.cgltf_data,
    instances: *std.ArrayList(Instance),
) !void {
    var matrix = parent_matrix;
    if (node.mesh != null) {
        if (node.*.has_translation != 0) matrix = matrix.mul(Mat4.translation(
            node.translation[0],
            node.translation[1],
            node.translation[2],
        ));

        if (node.has_rotation != 0) matrix = matrix.mul(
            Mat4.rotationFromQuaternion(
                [4]f32{
                    node.rotation[3],
                    node.rotation[0],
                    node.rotation[1],
                    node.rotation[2],
                },
            ),
        );

        if (node.has_scale != 0) matrix = matrix.mul(Mat4.scaling(
            node.scale[0],
            node.scale[1],
            node.scale[2],
        ));

        try instances.append(.{
            .mesh_index = @divExact(@intFromPtr(node.mesh) - @intFromPtr(gltf_data.meshes), @sizeOf(c.cgltf_mesh)),
            .transform = matrix.transpose(),
        });
    }

    if (node.children_count != 0) {
        for (node.children[0..node.children_count]) |child| {
            try loadSceneImpl(
                child,
                matrix,
                gltf_data,
                instances,
            );
        }
    }
}
