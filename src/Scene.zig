const std = @import("std");

const Mat4 = @import("Mat4.zig");

const c = @cImport({
    @cInclude("cgltf.h");
    @cInclude("stb_image.h");
});

const Self = @This();

pub const MeshIndices = struct {
    index_start: u32,
    index_end: u32,
    vertex_start: u32,
    vertex_end: u32,
};

pub const Material = union(enum) {
    texture: struct {
        data: []const u8,
        width: u32,
        height: u32,
    },
    color: [4]f32,
};

pub const Instance = struct {
    mesh_index: usize,
    transform: Mat4,
};

indices: []const u32,
positions: []const [4]f32,
normals: []const [4]f32,
tangents: []const [4]f32,
uvs: []const [2]f32,
material_indices: []const u32,

mesh_indices: []const MeshIndices,

albedo_textures: []const Material,
metal_roughness_textures: []const Material,
emissive_textures: []const Material,
normal_textures: []const Material,

instances: []const Instance,

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
    try self.loadMeshes(gltf_data, allocator);
    errdefer {
        allocator.free(self.mesh_indices);
        allocator.free(self.material_indices);
        allocator.free(self.uvs);
        allocator.free(self.normals);
        allocator.free(self.positions);
        allocator.free(self.indices);
    }

    const scene_dirname = std.fs.path.dirname(path) orelse "";
    try self.loadMaterials(gltf_data, scene_dirname, allocator);
    errdefer {
        for (self.normal_textures) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(self.normal_textures);

        for (self.emissive_textures) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(self.emissive_textures);

        for (self.metal_roughness_textures) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(self.metal_roughness_textures);

        for (self.albedo_textures) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(self.albedo_textures);
    }

    try self.loadScene(gltf_data, allocator);
    errdefer allocator.free(self.instances);

    return self;
}

pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void {
    allocator.free(self.instances);

    for (self.normal_textures) |m| {
        switch (m) {
            .texture => |t| allocator.free(t.data),
            .color => {},
        }
    }
    allocator.free(self.normal_textures);

    for (self.emissive_textures) |m| {
        switch (m) {
            .texture => |t| allocator.free(t.data),
            .color => {},
        }
    }
    allocator.free(self.emissive_textures);

    for (self.metal_roughness_textures) |m| {
        switch (m) {
            .texture => |t| allocator.free(t.data),
            .color => {},
        }
    }
    allocator.free(self.metal_roughness_textures);

    for (self.albedo_textures) |m| {
        switch (m) {
            .texture => |t| allocator.free(t.data),
            .color => {},
        }
    }
    allocator.free(self.albedo_textures);

    allocator.free(self.mesh_indices);

    allocator.free(self.material_indices);
    allocator.free(self.uvs);
    allocator.free(self.tangents);
    allocator.free(self.normals);
    allocator.free(self.positions);
    allocator.free(self.indices);
}

fn loadMeshes(
    self: *Self,
    gltf_data: *const c.cgltf_data,
    allocator: std.mem.Allocator,
) !void {
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

    const mesh_indices = try allocator.alloc(MeshIndices, gltf_data.meshes_count);
    errdefer allocator.free(mesh_indices);

    for (gltf_data.meshes[0..gltf_data.meshes_count], 0..) |mesh, i| {
        const index_start = indices.items.len;
        const vertex_start = positions.items.len;

        var max_index: u32 = 0;
        for (mesh.primitives[0..mesh.primitives_count]) |primitive| {
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
                        indices.appendAssumeCapacity(index + max_index);
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
                        indices.appendAssumeCapacity(index + max_index);
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

            max_index += @intCast(positions_buffer.len);

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
        }

        mesh_indices[i] = .{
            .index_start = @intCast(index_start),
            .index_end = @intCast(indices.items.len),
            .vertex_start = @intCast(vertex_start),
            .vertex_end = @intCast(positions.items.len),
        };
    }

    self.indices = try indices.toOwnedSlice();
    self.positions = try positions.toOwnedSlice();
    self.normals = try normals.toOwnedSlice();
    self.tangents = try tangents.toOwnedSlice();
    self.uvs = try uvs.toOwnedSlice();
    self.material_indices = try material_indices.toOwnedSlice();

    self.mesh_indices = mesh_indices;
}

fn loadMaterials(
    self: *Self,
    gltf_data: *const c.cgltf_data,
    cwd_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var albedo_index: usize = 0;
    const albedo_textures = try allocator.alloc(Material, gltf_data.materials_count);
    errdefer {
        for (albedo_textures[0..albedo_index]) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(albedo_textures);
    }

    var metal_index: usize = 0;
    const metal_roughness_textures = try allocator.alloc(Material, gltf_data.materials_count);
    errdefer {
        for (metal_roughness_textures[0..metal_index]) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(metal_roughness_textures);
    }

    var emissive_index: usize = 0;
    const emissive_textures = try allocator.alloc(Material, gltf_data.materials_count);
    errdefer {
        for (emissive_textures[0..metal_index]) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(emissive_textures);
    }

    var normal_index: usize = 0;
    const normal_textures = try allocator.alloc(Material, gltf_data.materials_count);
    errdefer {
        for (normal_textures[0..metal_index]) |m| {
            switch (m) {
                .texture => |t| allocator.free(t.data),
                .color => {},
            }
        }
        allocator.free(normal_textures);
    }

    const buffer: [*]const u8 = @ptrCast(gltf_data.buffers.*.data);

    for (gltf_data.materials[0..gltf_data.materials_count]) |material| {
        if (material.has_pbr_metallic_roughness == 0) return error.FailedToLoadMaterials;

        albedo_textures[albedo_index] = try loadTexture(
            material.pbr_metallic_roughness.base_color_texture.texture,
            cwd_path,
            buffer,
            .{
                1.0,
                material.pbr_metallic_roughness.base_color_factor[2],
                material.pbr_metallic_roughness.base_color_factor[1],
                material.pbr_metallic_roughness.base_color_factor[0],
            },
            allocator,
        );
        albedo_index += 1;

        metal_roughness_textures[metal_index] = try loadTexture(
            material.pbr_metallic_roughness.metallic_roughness_texture.texture,
            cwd_path,
            buffer,
            .{
                0.0,
                material.pbr_metallic_roughness.metallic_factor,
                material.pbr_metallic_roughness.roughness_factor,
                0.0,
            },
            allocator,
        );
        metal_index += 1;

        emissive_textures[emissive_index] = try loadTexture(
            material.emissive_texture.texture,
            cwd_path,
            buffer,
            .{
                0.0,
                material.emissive_factor[2],
                material.emissive_factor[1],
                material.emissive_factor[0],
            },
            allocator,
        );
        emissive_index += 1;

        normal_textures[normal_index] = try loadTexture(
            material.normal_texture.texture,
            cwd_path,
            buffer,
            .{
                0.0,
                1.0,
                0.5,
                0.5,
            },
            allocator,
        );
        normal_index += 1;
    }

    self.normal_textures = normal_textures;
    self.emissive_textures = emissive_textures;
    self.metal_roughness_textures = metal_roughness_textures;
    self.albedo_textures = albedo_textures;
}

pub fn loadTexture(
    maybe_texture: ?*const c.cgltf_texture,
    cwd_path: []const u8,
    buffer: [*]const u8,
    placeholder_color: [4]f32,
    allocator: std.mem.Allocator,
) !Material {
    if (maybe_texture) |texture| {
        if (texture.image.*.uri != null) {
            const albedo_path = try std.fs.path.joinZ(allocator, &.{
                cwd_path,
                std.mem.span(texture.*.image.*.uri),
            });
            defer allocator.free(albedo_path);

            var w: c_int = undefined;
            var h: c_int = undefined;
            var n: c_int = undefined;
            const image_data = c.stbi_load(
                albedo_path,
                &w,
                &h,
                &n,
                4,
            ) orelse return error.FailedToLoadMaterials;
            defer c.stbi_image_free(image_data);

            const width: u32 = @intCast(w);
            const height: u32 = @intCast(h);

            return .{
                .texture = .{
                    .data = try allocator.dupe(u8, image_data[0..(width * height * 4)]),
                    .width = width,
                    .height = height,
                },
            };
        } else if (texture.image.*.buffer_view != null) {
            const image_buffer = buffer[texture.*.image.*.buffer_view.*.offset..][0..texture.*.image.*.buffer_view.*.size];

            var w: c_int = undefined;
            var h: c_int = undefined;
            var n: c_int = undefined;

            const image_data = c.stbi_load_from_memory(
                @ptrCast(image_buffer.ptr),
                @intCast(image_buffer.len),
                &w,
                &h,
                &n,
                4,
            ) orelse return error.FailedToLoadMaterials;
            defer c.stbi_image_free(image_data);

            const width: u32 = @intCast(w);
            const height: u32 = @intCast(h);

            return .{
                .texture = .{
                    .data = try allocator.dupe(u8, image_data[0..(width * height * 4)]),
                    .width = width,
                    .height = height,
                },
            };
        }
    }

    return .{ .color = placeholder_color };
}

fn loadScene(
    self: *Self,
    gltf_data: *const c.cgltf_data,
    allocator: std.mem.Allocator,
) !void {
    var instances = std.ArrayList(Instance).init(allocator);
    errdefer instances.deinit();

    for (gltf_data.scene.*.nodes[0..gltf_data.scene.*.nodes_count]) |node| {
        try loadSceneImpl(
            node,
            Mat4.identity(),
            gltf_data,
            &instances,
        );
    }

    self.instances = try instances.toOwnedSlice();
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
            // .transform = matrix,
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
