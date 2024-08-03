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

        for (gltf_data.buffer_views[0..gltf_data.buffer_views_count]) |*buffer_view| {
            const buffer: [*]u8 = @ptrCast(buffer_view.buffer.*.data);
            buffer_view.data = @ptrCast(buffer[buffer_view.offset..]);
        }

        break :blk gltf_data;
    };
    defer {
        for (gltf_data.buffer_views[0..gltf_data.buffer_views_count]) |*buffer_view| {
            buffer_view.data = null;
        }
        c.cgltf_free(@ptrCast(gltf_data));
    }

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

    const meshes = try arena_allocator.alloc(Mesh, gltf_data.meshes_count);

    const primitives, const triangle_data, const offsets = blk: {
        var primitives_count: usize = 0;

        var sizes = [_]usize{0} ** 5;

        var largest_stride: usize = 0;
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

                var accessors = [_]?*c.cgltf_accessor{null} ** 5;
                accessors[0] = gltf_primitive.indices;

                for (gltf_primitive.attributes[0..gltf_primitive.attributes_count]) |attr| {
                    switch (attr.type) {
                        c.cgltf_attribute_type_position => accessors[1] = attr.data,
                        c.cgltf_attribute_type_normal => accessors[2] = attr.data,
                        c.cgltf_attribute_type_tangent => accessors[3] = attr.data,
                        c.cgltf_attribute_type_texcoord => {
                            if (accessors[4] == null) accessors[4] = attr.data;
                        },
                        else => {},
                    }
                }

                sizes[0] = std.mem.alignForward(usize, sizes[0], gltf_primitive.indices.*.stride);

                for (&sizes, accessors) |*size, maybe_acc| {
                    const acc = maybe_acc orelse return error.GLTFMissingData;
                    size.* += acc.count * acc.stride;
                    largest_stride = @max(largest_stride, acc.stride);
                }
            }
        }

        var offsets: [5]usize = undefined;
        var total_size: usize = 0;
        for (&sizes, &offsets) |*size, *offset| {
            offset.* = total_size;
            size.* = std.mem.alignForward(usize, size.*, largest_stride);
            total_size += size.*;
        }

        break :blk .{
            try arena_allocator.alloc(Primitive, primitives_count),
            try arena_allocator.alloc(u8, total_size),
            offsets,
        };
    };

    {
        var buffer_indices = offsets;
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
                var accessors = [_]?*c.cgltf_accessor{null} ** 5;
                accessors[0] = gltf_primitive.indices;

                for (gltf_primitive.attributes[0..gltf_primitive.attributes_count]) |attr| {
                    switch (attr.type) {
                        c.cgltf_attribute_type_position => accessors[1] = attr.data,
                        c.cgltf_attribute_type_normal => accessors[2] = attr.data,
                        c.cgltf_attribute_type_tangent => accessors[3] = attr.data,
                        c.cgltf_attribute_type_texcoord => {
                            if (accessors[4] == null) accessors[4] = attr.data;
                        },
                        else => {},
                    }
                }

                buffer_indices[0] = std.mem.alignForward(usize, buffer_indices[0], gltf_primitive.indices.*.stride);

                const positions_acc = accessors[1].?;

                primitive.* = .{
                    .indices_offset = buffer_indices[0],
                    .positions_offset = buffer_indices[1],
                    .normals_offset = buffer_indices[2],
                    .tangents_offset = buffer_indices[3],
                    .uvs_offset = buffer_indices[4],
                    .max_vertex = @intCast(positions_acc.count),
                    .triangle_count = @intCast(gltf_primitive.indices.*.count / 3),
                    .info = .{
                        .material_index = @intCast((@intFromPtr(gltf_primitive.material) -
                            @intFromPtr(gltf_data.materials)) / @sizeOf(c.cgltf_material)),
                        .uint32_indices = switch (gltf_primitive.indices.*.stride) {
                            2 => false,
                            4 => true,
                            else => unreachable,
                        },
                    },
                };

                for (&buffer_indices, &accessors) |*index, maybe_acc| {
                    const acc = maybe_acc.?;
                    const start = index.*;
                    const size = acc.count * acc.stride;
                    index.* += size;
                    const buffer_view: [*]const u8 = @ptrCast(acc.buffer_view.*.data);
                    std.mem.copyForwards(
                        u8,
                        triangle_data[start..index.*],
                        buffer_view[acc.offset..][0..size],
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
