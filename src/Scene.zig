const std = @import("std");
const vk = @import("vulkan");
const za = @import("zalgebra");

const zgltf = @import("zgltf");
const Gltf = zgltf.Gltf(.{
    .include = .{ .cameras = false },
});

const zi = @import("zigimg");

const Self = @This();

pub const Instance = struct {
    mesh_index: usize,
    transform: za.Mat4,
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

pub const Material = extern struct {
    albedo_factor: u32,
    metal_roughness_factor: u32,
    emissive_factor: u32,

    albedo_texture_index: u32,
    metal_roughness_texture_index: u32,
    emissive_texture_index: u32,
    normal_texture_index: u32,
};

pub const Texture = struct {
    data: []const u8,
    width: u32,
    height: u32,
};

const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

const Buffer = struct {
    offset: usize,
    file: std.fs.File,
};

arena: std.heap.ArenaAllocator,

instances: []const Instance,
meshes: []const Mesh,
primitives: []const Primitive,
triangle_data: []const u8,

materials: []const Material,

textures: []const Texture,

pub fn load(path: []const u8, allocator: std.mem.Allocator) !Self {
    var gltf_file = try std.fs.cwd().openFile(path, .{});
    defer gltf_file.close();

    var gltf_arena = std.heap.ArenaAllocator.init(allocator);
    defer gltf_arena.deinit();

    const gltf_data, const buffers = blk: {
        const file_extension = std.fs.path.extension(path);
        if (std.mem.eql(u8, file_extension, ".glb")) {
            const result = try zgltf.parseGlb(
                Gltf,
                gltf_file.reader(),
                gltf_arena.allocator(),
                allocator,
            );
            const buffers = try gltf_arena.allocator().alloc(Buffer, 1);
            buffers[0] = .{
                .offset = result.buffer_offset,
                .file = gltf_file,
            };

            break :blk .{
                result.gltf,
                buffers,
            };
        } else if (std.mem.eql(u8, file_extension, ".gltf")) {
            const result = try zgltf.parseGltf(
                Gltf,
                gltf_file.reader(),
                gltf_arena.allocator(),
                allocator,
            );

            var buffer_index: usize = 0;
            const buffers = try gltf_arena.allocator().alloc(Buffer, result.buffers.len);
            errdefer for (buffers[0..buffer_index]) |buffer| {
                buffer.file.close();
            };

            for (buffers, result.buffers) |*buffer, gltf_buffer| {
                buffer.* = .{
                    .offset = 0,
                    .file = try std.fs.cwd().openFile(gltf_buffer.uri, .{}),
                };
                buffer_index += 1;
            }

            break :blk .{
                result,
                buffers,
            };
        }
        return error.InvalidFileExtension;
    };
    defer for (buffers) |buffer| {
        if (buffer.offset == 0) buffer.file.close();
    };

    var self: Self = undefined;
    self.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer self.arena.deinit();

    try self.loadMeshes(gltf_data, buffers);

    try self.loadTextures(gltf_data, buffers, std.fs.cwd(), allocator);

    try self.loadMaterials(gltf_data);

    try self.loadScene(gltf_data, allocator);

    return self;
}

pub fn deinit(self: *const Self) void {
    self.arena.deinit();
}

fn loadMeshes(
    self: *Self,
    gltf_data: Gltf,
    gltf_buffers: []const Buffer,
) !void {
    const arena_allocator = self.arena.allocator();

    const meshes = try arena_allocator.alloc(Mesh, gltf_data.meshes.len);

    const offsets, const primitives, const triangle_data = blk: {
        var primitive_index: u32 = 0;

        var sizes = [_]usize{0} ** 5;
        var largest_stride: usize = 0;
        for (gltf_data.meshes, meshes) |gltf_mesh, *mesh| {
            for (gltf_mesh.primitives) |gltf_primitive| {
                if (gltf_primitive.mode != .triangles) return error.GltfNotATriangleTopology;

                const indices = gltf_primitive.indices.getOrNull() orelse return error.GltfNoIndices;
                const positions = gltf_primitive.attributes.position.getOrNull() orelse return error.GltfNoPositions;
                const normals = gltf_primitive.attributes.normal.getOrNull() orelse return error.GltfNoNormals;
                const tangents = gltf_primitive.attributes.tangent.getOrNull() orelse return error.GltfNoTangents;
                const texcoords = gltf_primitive.attributes.texcoord_0.getOrNull() orelse return error.GltfNoTextureCoordinates;

                const accessors = [_]Gltf.Accessor{
                    gltf_data.accessors[indices],
                    gltf_data.accessors[positions],
                    gltf_data.accessors[normals],
                    gltf_data.accessors[tangents],
                    gltf_data.accessors[texcoords],
                };

                for (accessors, &sizes) |accessor, *size| {
                    size.* += accessor.count * accessor.component_type.size() * accessor.type.count();
                    largest_stride = @max(
                        largest_stride,
                        accessor.count * accessor.component_type.size() * accessor.type.count(),
                    );
                }
            }

            const primitives_start = primitive_index;
            primitive_index += @intCast(gltf_mesh.primitives.len);
            mesh.* = .{
                .start = primitives_start,
                .end = primitive_index,
            };
        }

        largest_stride = std.math.ceilPowerOfTwoAssert(usize, largest_stride);

        var offsets: [5]usize = undefined;
        var total_size: usize = 0;
        for (&sizes, &offsets) |*size, *offset| {
            offset.* = total_size;
            size.* = std.mem.alignForward(usize, size.*, largest_stride);
            total_size += size.*;
        }

        break :blk .{
            offsets,
            try arena_allocator.alloc(Primitive, primitive_index),
            try arena_allocator.alloc(u8, total_size),
        };
    };

    {
        var buffer_indices = offsets;
        for (gltf_data.meshes, meshes) |gltf_mesh, mesh| {
            for (gltf_mesh.primitives, primitives[mesh.start..mesh.end]) |gltf_primitive, *primitive| {
                const indices = gltf_data.accessors[gltf_primitive.indices.get()];
                const positions = gltf_data.accessors[gltf_primitive.attributes.position.get()];
                const normals = gltf_data.accessors[gltf_primitive.attributes.normal.get()];
                const tangents = gltf_data.accessors[gltf_primitive.attributes.tangent.get()];
                const texcoords = gltf_data.accessors[gltf_primitive.attributes.texcoord_0.get()];

                buffer_indices[0] = std.mem.alignForward(
                    usize,
                    buffer_indices[0],
                    indices.component_type.size(),
                );

                primitive.* = .{
                    .indices_offset = buffer_indices[0],
                    .positions_offset = buffer_indices[1],
                    .normals_offset = buffer_indices[2],
                    .tangents_offset = buffer_indices[3],
                    .uvs_offset = buffer_indices[4],
                    .max_vertex = positions.count - 1,
                    .triangle_count = @intCast(indices.count / 3),
                    .info = .{
                        .material_index = @intCast(gltf_primitive.material.getOrNull() orelse return error.NoMaterial),
                        .uint32_indices = switch (indices.component_type) {
                            .unsigned_short => false,
                            .unsigned_int => true,
                            else => unreachable,
                        },
                    },
                };

                // Read indices
                {
                    const start = buffer_indices[0];
                    const size = indices.count * indices.component_type.size();
                    buffer_indices[0] += size;

                    const buffer_view = gltf_data.buffer_views[indices.buffer_view.getOrNull() orelse return error.NoBufferView];
                    const buffer = gltf_buffers[buffer_view.buffer.get()];

                    try buffer.file.seekTo(buffer.offset + indices.byte_offset + buffer_view.byte_offset);
                    const read_size = try buffer.file.read(triangle_data[start..][0..size]);
                    if (read_size != size) return error.EndOfFile;
                }

                // Read positions
                {
                    const start = buffer_indices[1];
                    if (positions.type != .vec3) return error.InvalidPositionType;
                    const size = positions.count * positions.type.count() * positions.component_type.size();
                    buffer_indices[1] += size;

                    const buffer_view = gltf_data.buffer_views[positions.buffer_view.getOrNull() orelse return error.NoBufferView];
                    const buffer = gltf_buffers[buffer_view.buffer.get()];

                    try buffer.file.seekTo(buffer.offset + positions.byte_offset + buffer_view.byte_offset);
                    const read_size = try buffer.file.read(triangle_data[start..][0..size]);
                    if (read_size != size) return error.EndOfFile;
                }

                // Read normals
                {
                    const start = buffer_indices[2];
                    if (normals.type != .vec3) return error.InvalidNormalType;
                    const size = normals.count * normals.type.count() * normals.component_type.size();
                    buffer_indices[2] += size;

                    const buffer_view = gltf_data.buffer_views[normals.buffer_view.getOrNull() orelse return error.NoBufferView];
                    const buffer = gltf_buffers[buffer_view.buffer.get()];

                    try buffer.file.seekTo(buffer.offset + normals.byte_offset + buffer_view.byte_offset);
                    const read_size = try buffer.file.read(triangle_data[start..][0..size]);
                    if (read_size != size) return error.EndOfFile;
                }

                // Read tangents
                {
                    const start = buffer_indices[3];
                    if (tangents.type != .vec4) return error.InvalidTangentType;
                    const size = tangents.count * tangents.type.count() * tangents.component_type.size();
                    buffer_indices[3] += size;

                    const buffer_view = gltf_data.buffer_views[tangents.buffer_view.getOrNull() orelse return error.NoBufferView];
                    const buffer = gltf_buffers[buffer_view.buffer.get()];

                    try buffer.file.seekTo(buffer.offset + tangents.byte_offset + buffer_view.byte_offset);
                    const read_size = try buffer.file.read(triangle_data[start..][0..size]);
                    if (read_size != size) return error.EndOfFile;
                }

                // Read texture coordinates
                {
                    const start = buffer_indices[4];
                    if (texcoords.type != .vec2) return error.InvalidTexcoordType;
                    const size = texcoords.count * texcoords.type.count() * texcoords.component_type.size();
                    buffer_indices[4] += size;

                    const buffer_view = gltf_data.buffer_views[texcoords.buffer_view.getOrNull() orelse return error.NoBufferView];
                    const buffer = gltf_buffers[buffer_view.buffer.get()];

                    try buffer.file.seekTo(buffer.offset + texcoords.byte_offset + buffer_view.byte_offset);
                    const read_size = try buffer.file.read(triangle_data[start..][0..size]);
                    if (read_size != size) return error.EndOfFile;
                }
            }
        }
    }

    {
        var primitive_index: u32 = 0;
        for (gltf_data.meshes, meshes) |gltf_mesh, *mesh| {
            const start = primitive_index;
            primitive_index += @intCast(gltf_mesh.primitives.len);
            mesh.* = .{
                .start = start,
                .end = primitive_index,
            };
        }
    }

    self.triangle_data = triangle_data;
    self.primitives = primitives;
    self.meshes = meshes;
}

fn loadTextures(
    self: *Self,
    gltf_data: Gltf,
    gltf_buffers: []const Buffer,
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
) !void {
    if (gltf_data.textures.len == 0) {
        self.textures = &.{};
        return;
    }

    const arena_allocator = self.arena.allocator();

    const textures = try arena_allocator.alloc(Texture, gltf_data.textures.len);

    for (gltf_data.textures, textures) |gltf_texture, *texture| {
        const image = gltf_data.images[gltf_texture.source.get()];
        var image_data = if (image.uri.len != 0) blk: {
            var file = try dir.openFile(image.uri, .{});
            defer file.close();

            break :blk try zi.Image.fromFile(allocator, &file);
        } else blk: {
            const buffer_view = gltf_data.buffer_views[image.buffer_view.get()];
            const buffer = gltf_buffers[buffer_view.buffer.get()];

            const image_data = try allocator.alloc(u8, buffer_view.byte_length);
            defer allocator.free(image_data);

            try buffer.file.seekTo(buffer.offset + buffer_view.byte_offset);
            const read_size = try buffer.file.read(image_data);
            if (read_size != buffer_view.byte_length) return error.EndOfLength;

            break :blk try zi.Image.fromMemory(allocator, image_data);
        };
        defer image_data.deinit();

        texture.* = .{
            .data = switch (image_data.pixelFormat()) {
                .rgba32 => try arena_allocator.dupe(u8, image_data.pixels.asConstBytes()),
                else => blk: {
                    const pixels = try zi.PixelFormatConverter.convert(
                        arena_allocator,
                        &image_data.pixels,
                        .rgba32,
                    );
                    break :blk pixels.asConstBytes();
                },
            },
            .width = @intCast(image_data.width),
            .height = @intCast(image_data.height),
        };
    }

    self.textures = textures;
}

fn loadMaterials(
    self: *Self,
    gltf_data: Gltf,
) !void {
    const materials = try self.arena.allocator().alloc(Material, gltf_data.materials.len);

    for (gltf_data.materials, materials) |gltf_material, *material| {
        const pbr = gltf_material.pbr_metallic_roughness orelse return error.NonPbrMaterial;

        material.* = .{
            .albedo_factor = @bitCast(Color{
                .r = @intFromFloat(pbr.base_color_factor[0] * 255.0),
                .g = @intFromFloat(pbr.base_color_factor[1] * 255.0),
                .b = @intFromFloat(pbr.base_color_factor[2] * 255.0),
                .a = 0,
            }),
            .metal_roughness_factor = @bitCast(Color{
                .r = 0,
                .g = @intFromFloat(pbr.roughness_factor * 255.0),
                .b = @intFromFloat(pbr.metallic_factor * 255.0),
                .a = 0,
            }),
            .emissive_factor = @bitCast(Color{
                .r = @intFromFloat(gltf_material.emissive_factor[0] * 255.0),
                .g = @intFromFloat(gltf_material.emissive_factor[1] * 255.0),
                .b = @intFromFloat(gltf_material.emissive_factor[2] * 255.0),
                .a = 0,
            }),

            .albedo_texture_index = if (pbr.base_color_texture) |texture| texture.index.get() else 0xffffffff,
            .metal_roughness_texture_index = if (pbr.metallic_roughness_texture) |texture| texture.index.get() else 0xffffffff,
            .emissive_texture_index = if (gltf_material.emissive_texture) |texture| texture.index.get() else 0xffffffff,
            .normal_texture_index = if (gltf_material.normal_texture) |texture| texture.index.get() else 0xffffffff,
        };
    }

    self.materials = materials;
}

fn loadScene(
    self: *Self,
    gltf_data: Gltf,
    allocator: std.mem.Allocator,
) !void {
    var instances = std.ArrayList(Instance).init(allocator);
    defer instances.deinit();

    if (gltf_data.scenes.len == 0) return error.NoScene;
    if (gltf_data.scenes.len > 1) return error.TooManyScenes;

    for (gltf_data.scenes[0].nodes) |node| {
        try loadSceneImpl(
            gltf_data.nodes[node],
            za.Mat4.identity(),
            gltf_data,
            &instances,
        );
    }

    self.instances = try self.arena.allocator().dupe(Instance, instances.items);
}

fn loadSceneImpl(
    node: Gltf.Node,
    parent_matrix: za.Mat4,
    gltf_data: Gltf,
    instances: *std.ArrayList(Instance),
) !void {
    var matrix = parent_matrix;
    if (node.mesh.getOrNull()) |mesh_index| {
        matrix = matrix.translate(za.Vec3.fromSlice(&node.translation));

        matrix = matrix.mul(za.Quat.new(
            node.rotation[3],
            node.rotation[0],
            node.rotation[1],
            node.rotation[2],
        ).toMat4());

        matrix = matrix.scale(za.Vec3.fromSlice(&node.scale));

        try instances.append(.{
            .mesh_index = mesh_index,
            .transform = matrix.transpose(),
        });
    }

    for (node.children) |child_index| {
        try loadSceneImpl(
            gltf_data.nodes[child_index],
            matrix,
            gltf_data,
            instances,
        );
    }
}
