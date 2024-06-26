const std = @import("std");
const vk = @import("vulkan");
const Scene = @import("Scene.zig");

const Camera = @import("Camera.zig");

const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");

const BLAS = @import("BLAS.zig");
const TLAS = @import("TLAS.zig");

const RayTracingPipeline = @import("RayTracingPipeline.zig");

const Self = @This();

const ObjDesc = struct {
    index_address: vk.DeviceAddress,
    normal_address: vk.DeviceAddress,
    tangent_address: vk.DeviceAddress,
    uv_address: vk.DeviceAddress,
    material_address: vk.DeviceAddress,
};

blases: []BLAS,
tlas: TLAS,
albedos: []const Image,
metal_roughness: []const Image,
emissive: []const Image,
normals: []const Image,
blas_buffer: Buffer,
obj_descs: Buffer,

storage_image: Image,
pipeline: RayTracingPipeline,

pub fn init(
    instance: *const Instance,
    device: *const Device,
    extent: vk.Extent2D,
    format: vk.Format,
    pool: vk.CommandPool,
    allocator: std.mem.Allocator,
    scene_path: []const u8,
    num_samples: u32,
    num_bounces: u32,
) !Self {
    const scene = try Scene.load(scene_path, allocator);
    defer scene.deinit(allocator);

    const blases_and_buffer = try createBlases(
        device,
        &scene,
        pool,
        allocator,
    );
    errdefer {
        for (blases_and_buffer.blases) |blas| {
            blas.deinit(device);
        }
        allocator.free(blases_and_buffer.blases);
        blases_and_buffer.buffer.deinit(device);
    }
    defer allocator.free(blases_and_buffer.obj_descs);

    const albedos = try createTextures(
        device,
        pool,
        scene.albedo_textures,
        allocator,
    );
    errdefer {
        for (albedos) |t| {
            t.deinit(device);
        }
        allocator.free(albedos);
    }

    const metal_roughness = try createTextures(
        device,
        pool,
        scene.metal_roughness_textures,
        allocator,
    );
    errdefer {
        for (metal_roughness) |t| {
            t.deinit(device);
        }
        allocator.free(metal_roughness);
    }

    const emissive = try createTextures(
        device,
        pool,
        scene.emissive_textures,
        allocator,
    );
    errdefer {
        for (emissive) |t| {
            t.deinit(device);
        }
        allocator.free(emissive);
    }

    const normals = try createTextures(
        device,
        pool,
        scene.normal_textures,
        allocator,
    );
    errdefer {
        for (normals) |t| {
            t.deinit(device);
        }
        allocator.free(normals);
    }

    const tlas = try TLAS.init(
        device,
        pool,
        blases_and_buffer.blases,
        scene.instances,
        allocator,
    );
    errdefer tlas.deinit(device);

    const obj_descs = blases_and_buffer.obj_descs;

    const obj_desc_buffer = try Buffer.initAndUpload(
        device,
        ObjDesc,
        obj_descs,
        .{
            .shader_device_address_bit = true,
            .storage_buffer_bit = true,
        },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
        pool,
    );
    errdefer obj_desc_buffer.deinit(device);

    var storage_image = try Image.init(
        device,
        extent,
        format,
        .{
            .transfer_src_bit = true,
            .storage_bit = true,
        },
        .optimal,
        .undefined,
        .{ .device_local_bit = true },
        .{},
    );
    errdefer storage_image.deinit(device);
    try storage_image.transistionLayout(device, pool, .undefined, .general);

    const pipeline = try RayTracingPipeline.init(
        instance,
        device,
        &tlas,
        storage_image.view,
        obj_desc_buffer.buffer,
        albedos,
        metal_roughness,
        emissive,
        normals,
        num_samples,
        num_bounces,
        allocator,
    );
    errdefer pipeline.deinit(device);

    return .{
        .blases = blases_and_buffer.blases,
        .blas_buffer = blases_and_buffer.buffer,
        .tlas = tlas,
        .obj_descs = obj_desc_buffer,
        .albedos = albedos,
        .metal_roughness = metal_roughness,
        .emissive = emissive,
        .normals = normals,

        .storage_image = storage_image,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: *Self, device: *const Device, allocator: std.mem.Allocator) void {
    self.pipeline.deinit(device);
    self.storage_image.deinit(device);

    self.obj_descs.deinit(device);

    self.tlas.deinit(device);

    for (self.blases) |blas| {
        blas.deinit(device);
    }
    allocator.free(self.blases);

    self.blas_buffer.deinit(device);

    for (self.normals) |t| {
        t.deinit(device);
    }
    allocator.free(self.normals);

    for (self.emissive) |t| {
        t.deinit(device);
    }
    allocator.free(self.emissive);

    for (self.metal_roughness) |t| {
        t.deinit(device);
    }
    allocator.free(self.metal_roughness);

    for (self.albedos) |t| {
        t.deinit(device);
    }
    allocator.free(self.albedos);
}

fn createBlases(
    device: *const Device,
    scene: *const Scene,
    pool: vk.CommandPool,
    allocator: std.mem.Allocator,
) !struct {
    blases: []BLAS,
    buffer: Buffer,
    obj_descs: []const ObjDesc,
} {
    const positions_size = scene.positions.len * @sizeOf([4]f32);
    const normals_size = scene.normals.len * @sizeOf([4]f32);
    const tangents_size = scene.tangents.len * @sizeOf([4]f32);
    const uvs_size = scene.uvs.len * @sizeOf([2]f32);
    const material_indices_size = scene.material_indices.len * @sizeOf(u32);
    const indices_size = scene.indices.len * @sizeOf(u32);
    const total_size = positions_size +
        normals_size +
        tangents_size +
        uvs_size +
        material_indices_size +
        indices_size;

    const staging_buffer = try Buffer.init(
        device,
        total_size,
        .{ .transfer_src_bit = true },
        .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
        .{},
    );
    defer staging_buffer.deinit(device);

    const positions_begin: usize = 0;
    const normals_begin: usize = positions_begin + positions_size;
    const tangents_begin: usize = normals_begin + normals_size;
    const uvs_begin: usize = tangents_begin + tangents_size;
    const material_indices_begin: usize = uvs_begin + uvs_size;
    const indices_begin: usize = material_indices_begin + material_indices_size;

    {
        const buffer_data: [*]u8 = @ptrCast(try device.vkd.mapMemory(
            device.device,
            staging_buffer.memory,
            0,
            vk.WHOLE_SIZE,
            .{},
        ));
        defer device.vkd.unmapMemory(device.device, staging_buffer.memory);

        const buffer_positions: [*][4]f32 = @alignCast(@ptrCast(buffer_data));
        for (scene.positions, 0..) |pos, i| {
            buffer_positions[i] = pos;
        }

        const buffer_normals: [*][4]f32 = @alignCast(@ptrCast(&buffer_data[normals_begin]));
        for (scene.normals, 0..) |normal, i| {
            buffer_normals[i] = normal;
        }

        const buffer_tangents: [*][4]f32 = @alignCast(@ptrCast(&buffer_data[tangents_begin]));
        for (scene.tangents, 0..) |tangent, i| {
            buffer_tangents[i] = tangent;
        }

        const buffer_uvs: [*][2]f32 = @alignCast(@ptrCast(&buffer_data[uvs_begin]));
        for (scene.uvs, 0..) |uv, i| {
            buffer_uvs[i] = uv;
        }

        const buffer_materials: [*]u32 = @alignCast(@ptrCast(&buffer_data[material_indices_begin]));
        for (scene.material_indices, 0..) |material, i| {
            buffer_materials[i] = material;
        }

        const buffer_indices: [*]u32 = @alignCast(@ptrCast(&buffer_data[indices_begin]));
        for (scene.indices, 0..) |index, i| {
            buffer_indices[i] = index;
        }
    }

    const gpu_buffer = try Buffer.init(
        device,
        total_size,
        .{
            .acceleration_structure_build_input_read_only_bit_khr = true,
            .shader_device_address_bit = true,
            .storage_buffer_bit = true,
            .transfer_dst_bit = true,
        },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    errdefer gpu_buffer.deinit(device);

    try gpu_buffer.oneTimeCopyFrom(
        staging_buffer,
        device,
        pool,
        total_size,
    );

    var blas_index: usize = 0;
    const blases = try allocator.alloc(BLAS, scene.mesh_indices.len);
    errdefer {
        for (blases[0..blas_index]) |blas| {
            blas.deinit(device);
        }
        allocator.free(blases);
    }

    const buffer_address = device.vkd.getBufferDeviceAddress(
        device.device,
        &.{ .buffer = gpu_buffer.buffer },
    );

    const obj_descs = try allocator.alloc(ObjDesc, blases.len);
    errdefer allocator.free(obj_descs);

    for (scene.mesh_indices, 0..) |mesh, i| {
        obj_descs[i] = .{
            .index_address = buffer_address + indices_begin + mesh.index_start * @sizeOf(u32),
            .normal_address = buffer_address + normals_begin + mesh.vertex_start * @sizeOf([4]f32),
            .tangent_address = buffer_address + tangents_begin + mesh.vertex_start * @sizeOf([4]f32),
            .uv_address = buffer_address + uvs_begin + mesh.vertex_start * @sizeOf([2]f32),
            .material_address = buffer_address + material_indices_begin + (mesh.index_start / 3) * @sizeOf(u32),
        };
        blases[blas_index] = try BLAS.init(
            device,
            pool,
            buffer_address + positions_begin + mesh.vertex_start * @sizeOf([4]f32),
            buffer_address + indices_begin + mesh.index_start * @sizeOf(u32),
            (mesh.index_end - mesh.index_start) / 3,
            mesh.vertex_end - mesh.vertex_start,
        );
        blas_index += 1;
    }

    return .{
        .blases = blases,
        .buffer = gpu_buffer,
        .obj_descs = obj_descs,
    };
}

fn createTextures(
    device: *const Device,
    pool: vk.CommandPool,
    materials: []const Scene.Material,
    allocator: std.mem.Allocator,
) ![]const Image {
    var texture_index: usize = 0;
    const textures = try allocator.alloc(Image, materials.len);
    errdefer {
        for (0..texture_index) |i| {
            textures[i].deinit(device);
        }
        allocator.free(textures);
    }

    for (materials, textures) |material, *texture| {
        switch (material) {
            .texture => |t| {
                texture.* = try Image.initAndUpload(
                    device,
                    t.data,
                    .{ .width = t.width, .height = t.height },
                    .r8g8b8a8_unorm,
                    .{
                        .transfer_dst_bit = true,
                        .sampled_bit = true,
                    },
                    .optimal,
                    .undefined,
                    .{ .device_local_bit = true },
                    .{},
                    pool,
                );
            },
            .color => |c| {
                const color_u32 = blk: {
                    const r: u8 = @intFromFloat(std.math.clamp(c[0] * 255.0, 0.0, 255.0));
                    const g: u8 = @intFromFloat(std.math.clamp(c[1] * 255.0, 0.0, 255.0));
                    const b: u8 = @intFromFloat(std.math.clamp(c[2] * 255.0, 0.0, 255.0));
                    const a: u8 = @intFromFloat(std.math.clamp(c[3] * 255.0, 0.0, 255.0));

                    break :blk (@as(u32, r) << 24) | (@as(u32, g) << 16) | (@as(u32, b) << 8) | @as(u32, a);
                };
                texture.* = try Image.initAndUpload(
                    device,
                    std.mem.asBytes(&color_u32),
                    .{ .width = 1, .height = 1 },
                    .r8g8b8a8_unorm,
                    .{
                        .transfer_dst_bit = true,
                        .sampled_bit = true,
                    },
                    .optimal,
                    .undefined,
                    .{ .device_local_bit = true },
                    .{},
                    pool,
                );
            },
        }

        texture_index += 1;
    }

    return textures;
}

pub fn record(
    self: *const Self,
    device: *const Device,
    dst_image: vk.Image,
    extent: vk.Extent2D,
    cmdbuf: vk.CommandBuffer,
    camera: Camera,
    frame_count: u32,
) !void {
    const handle_size_aligned = std.mem.alignForward(
        u32,
        self.pipeline.properties.shader_group_handle_size,
        self.pipeline.properties.shader_group_handle_alignment,
    );

    const ray_gen_shader_entry = vk.StridedDeviceAddressRegionKHR{
        .device_address = self.pipeline.ray_gen_device_address,
        .stride = handle_size_aligned,
        .size = handle_size_aligned,
    };

    const miss_shader_entry = vk.StridedDeviceAddressRegionKHR{
        .device_address = self.pipeline.miss_device_address,
        .stride = handle_size_aligned,
        .size = handle_size_aligned,
    };

    const closest_hit_shader_entry = vk.StridedDeviceAddressRegionKHR{
        .device_address = self.pipeline.closest_hit_device_address,
        .stride = handle_size_aligned,
        .size = handle_size_aligned,
    };

    const callable_shader_entry = vk.StridedDeviceAddressRegionKHR{
        .device_address = 0,
        .stride = 0,
        .size = 0,
    };

    device.vkd.cmdBindPipeline(cmdbuf, .ray_tracing_khr, self.pipeline.pipeline);
    device.vkd.cmdBindDescriptorSets(
        cmdbuf,
        .ray_tracing_khr,
        self.pipeline.pipeline_layout,
        0,
        1,
        @ptrCast(&self.pipeline.descriptor_set),
        0,
        undefined,
    );

    const push_constants = .{
        [4]f32{ camera.position.x, camera.position.y, camera.position.z, 1.0 },
        [4]f32{ camera.horizontal.x, camera.horizontal.y, camera.horizontal.z, 0.0 },
        [4]f32{ camera.vertical.x, camera.vertical.y, camera.vertical.z, 0.0 },
        [4]f32{ camera.forward.x, camera.forward.y, camera.forward.z, 0.0 },
        frame_count,
    };

    device.vkd.cmdPushConstants(
        cmdbuf,
        self.pipeline.pipeline_layout,
        .{ .raygen_bit_khr = true },
        0,
        128,
        @ptrCast(&push_constants),
    );

    device.vkd.cmdTraceRaysKHR(
        cmdbuf,
        &ray_gen_shader_entry,
        &miss_shader_entry,
        &closest_hit_shader_entry,
        &callable_shader_entry,
        extent.width,
        extent.height,
        1,
    );

    // Copy from storage image to destination image
    self.storage_image.setLayout(
        device,
        cmdbuf,
        .general,
        .transfer_src_optimal,
    );

    const image_copy = vk.ImageCopy{
        .src_offset = .{ .x = 0, .y = 0, .z = 0 },
        .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
        .src_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .dst_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .extent = .{
            .width = extent.width,
            .height = extent.height,
            .depth = 1,
        },
    };
    device.vkd.cmdCopyImage(
        cmdbuf,
        self.storage_image.image,
        .transfer_src_optimal,
        dst_image,
        .transfer_dst_optimal,
        1,
        @ptrCast(&image_copy),
    );

    self.storage_image.setLayout(
        device,
        cmdbuf,
        .transfer_src_optimal,
        .general,
    );
}

pub fn resize(
    self: *Self,
    device: *const Device,
    extent: vk.Extent2D,
    format: vk.Format,
    pool: vk.CommandPool,
) !void {
    self.storage_image.deinit(device);
    self.storage_image = try Image.init(
        device,
        extent,
        format,
        .{
            .transfer_src_bit = true,
            .storage_bit = true,
        },
        .optimal,
        .undefined,
        .{ .device_local_bit = true },
        .{},
    );
    try self.storage_image.transistionLayout(device, pool, .undefined, .general);

    self.pipeline.updateImageDescriptor(
        device,
        self.storage_image.view,
    );
}
