const std = @import("std");

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
    index_start: u32,
    index_end: u32,
    vertex_start: u32,
    vertex_end: u32,
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

indices: []const u32,
positions: []const [4]f32,
normals: []const [4]f32,
tangents: []const [4]f32,
uvs: []const [2]f32,
material_indices: []const u32,

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

    try self.loadMeshes(gltf_data, allocator);

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
    allocator: std.mem.Allocator,
) !void {
    const arena_allocator = self.arena.allocator();

    if (gltf_data.buffers_count != 1) return error.FailedToLoadGLTF;

    const buffer: [*]const u8 = @ptrCast(gltf_data.buffers.*.data);

    var indices = std.ArrayList(u32).init(allocator);
    defer indices.deinit();

    var positions = std.ArrayList([4]f32).init(allocator);
    defer positions.deinit();

    var normals = std.ArrayList([4]f32).init(allocator);
    defer normals.deinit();

    var tangents = std.ArrayList([4]f32).init(allocator);
    defer tangents.deinit();

    var uvs = std.ArrayList([2]f32).init(allocator);
    defer uvs.deinit();

    var material_indices = std.ArrayList(u32).init(allocator);
    defer material_indices.deinit();

    var primitives = std.ArrayList(Primitive).init(allocator);
    defer primitives.deinit();

    const meshes = try arena_allocator.alloc(Mesh, gltf_data.meshes_count);

    for (gltf_data.meshes[0..gltf_data.meshes_count], meshes) |gltf_mesh, *mesh| {
        const primitives_start = primitives.items.len;
        try primitives.ensureUnusedCapacity(gltf_mesh.primitives_count);
        for (gltf_mesh.primitives[0..gltf_mesh.primitives_count]) |primitive| {
            const index_start = indices.items.len;
            const vertex_start = positions.items.len;
            if (primitive.type != c.cgltf_primitive_type_triangles) return error.GLTFNotTriangles;

            if (primitive.indices == null) return error.GLTFNoIndices;

            const indices_acc = primitive.indices;
            var positions_acc: [*c]c.cgltf_accessor = null;
            var normals_acc: [*c]c.cgltf_accessor = null;
            var tangents_acc: [*c]c.cgltf_accessor = null;
            var uvs_acc: [*c]c.cgltf_accessor = null;
            for (primitive.attributes[0..primitive.attributes_count]) |attr| {
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

            if (positions_acc == null) return error.GLTFNoPositions;
            if (normals_acc == null) return error.GLTFNoNormals;
            if (tangents_acc == null) return error.GLTFNoTangents;
            if (uvs_acc == null) return error.GLTFNoUVs;

            var triangle_count: usize = 0;
            // Indices
            switch (indices_acc.*.component_type) {
                c.cgltf_component_type_r_16u => {
                    if (indices_acc.*.stride != 2) return error.FailedToLoadGLTF;
                    const indices_buffer: []const u16 = @alignCast(std.mem.bytesAsSlice(
                        u16,
                        buffer[(indices_acc.*.offset + indices_acc.*.buffer_view.*.offset)..][0..indices_acc.*.buffer_view.*.size],
                    ));
                    try indices.ensureUnusedCapacity(indices_buffer.len);
                    for (indices_buffer) |index| {
                        indices.appendAssumeCapacity(index);
                    }

                    triangle_count = indices_buffer.len / 3;
                },
                c.cgltf_component_type_r_32u => {
                    if (indices_acc.*.stride != 4) return error.FailedToLoadGLTF;
                    const indices_buffer: []const u32 = @alignCast(std.mem.bytesAsSlice(
                        u32,
                        buffer[(indices_acc.*.offset + indices_acc.*.buffer_view.*.offset)..][0..indices_acc.*.buffer_view.*.size],
                    ));
                    try indices.ensureUnusedCapacity(indices_buffer.len);
                    for (indices_buffer) |index| {
                        indices.appendAssumeCapacity(index);
                    }
                    triangle_count = indices_buffer.len / 3;
                },
                else => return error.FailedToLoadGLTF,
            }

            // Positions
            if (positions_acc.*.component_type != c.cgltf_component_type_r_32f or
                positions_acc.*.type != c.cgltf_type_vec3 or positions_acc.*.stride != 12) return error.FailedToLoadGLTF;

            const positions_buffer: []const [3]f32 = @alignCast(std.mem.bytesAsSlice(
                [3]f32,
                buffer[(positions_acc.*.offset + positions_acc.*.buffer_view.*.offset)..][0..positions_acc.*.buffer_view.*.size],
            ));

            try positions.ensureUnusedCapacity(positions_buffer.len);
            for (positions_buffer) |pos| {
                positions.appendAssumeCapacity(.{
                    pos[0],
                    pos[1],
                    pos[2],
                    0.0,
                });
            }

            // Normals
            if (normals_acc.*.component_type != c.cgltf_component_type_r_32f or
                normals_acc.*.type != c.cgltf_type_vec3 or normals_acc.*.stride != 12) return error.FailedToLoadGLTF;

            const normals_buffer: []const [3]f32 = @alignCast(std.mem.bytesAsSlice(
                [3]f32,
                buffer[(normals_acc.*.offset + normals_acc.*.buffer_view.*.offset)..][0..normals_acc.*.buffer_view.*.size],
            ));

            try normals.ensureUnusedCapacity(normals_buffer.len);
            for (normals_buffer) |normal| {
                normals.appendAssumeCapacity(.{
                    normal[0],
                    normal[1],
                    normal[2],
                    0.0,
                });
            }

            // Tangents
            if (tangents_acc.*.component_type != c.cgltf_component_type_r_32f or
                tangents_acc.*.type != c.cgltf_type_vec4 or tangents_acc.*.stride != 16) return error.FailedToLoadGLTF;

            const tangents_buffer: []const [4]f32 = @alignCast(std.mem.bytesAsSlice(
                [4]f32,
                buffer[(tangents_acc.*.offset + tangents_acc.*.buffer_view.*.offset)..][0..tangents_acc.*.buffer_view.*.size],
            ));

            try tangents.ensureUnusedCapacity(tangents_buffer.len);
            for (tangents_buffer) |tangent| {
                tangents.appendAssumeCapacity(.{
                    tangent[0],
                    tangent[1],
                    tangent[2],
                    tangent[3],
                });
            }

            // UVs
            if (uvs_acc.*.component_type != c.cgltf_component_type_r_32f or
                uvs_acc.*.type != c.cgltf_type_vec2 or uvs_acc.*.stride != 8) return error.FailedToLoadGLTF;

            const uvs_buffer: []const [2]f32 = @alignCast(std.mem.bytesAsSlice(
                [2]f32,
                buffer[(uvs_acc.*.offset + uvs_acc.*.buffer_view.*.offset)..][0..uvs_acc.*.buffer_view.*.size],
            ));

            try uvs.ensureUnusedCapacity(uvs_buffer.len);
            for (uvs_buffer) |uv| {
                uvs.appendAssumeCapacity(uv);
            }

            try material_indices.ensureUnusedCapacity(triangle_count);
            for (0..triangle_count) |_| {
                material_indices.appendAssumeCapacity(
                    @intCast((@intFromPtr(primitive.material) -
                        @intFromPtr(gltf_data.materials)) / @sizeOf(c.cgltf_material)),
                );
            }

            primitives.appendAssumeCapacity(.{
                .index_start = @intCast(index_start),
                .index_end = @intCast(indices.items.len),
                .vertex_start = @intCast(vertex_start),
                .vertex_end = @intCast(positions.items.len),
            });
        }

        mesh.* = .{
            .start = @intCast(primitives_start),
            .end = @intCast(primitives.items.len),
        };
    }

    self.indices = try arena_allocator.dupe(u32, indices.items);
    self.positions = try arena_allocator.dupe([4]f32, positions.items);
    self.normals = try arena_allocator.dupe([4]f32, normals.items);
    self.tangents = try arena_allocator.dupe([4]f32, tangents.items);
    self.uvs = try arena_allocator.dupe([2]f32, uvs.items);
    self.material_indices = try arena_allocator.dupe(u32, material_indices.items);

    self.primitives = try arena_allocator.dupe(Primitive, primitives.items);
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
            .b = @intFromFloat(material.pbr_metallic_roughness.base_color_factor[1] * 255.0),
            .g = @intFromFloat(material.pbr_metallic_roughness.base_color_factor[2] * 255.0),
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
            .b = @intFromFloat(material.emissive_factor[1] * 255.0),
            .g = @intFromFloat(material.emissive_factor[2] * 255.0),
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
