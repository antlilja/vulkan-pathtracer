const std = @import("std");
const vk = @import("vulkan");
const Scene = @import("Scene.zig");

const Camera = @import("Camera.zig");

const GraphicsContext = @import("GraphicsContext.zig");

const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");

const Tlas = @import("Tlas.zig");

const RayTracingPipeline = @import("RayTracingPipeline.zig");

const Self = @This();

const Primitive = extern struct {
    const Flags = packed struct(u32) {
        material_index: u24,
        reserved: u7 = 0,
        uin32_indices: bool,
    };

    index_address: vk.DeviceAddress,
    normal_address: vk.DeviceAddress,
    tangent_address: vk.DeviceAddress,
    uv_address: vk.DeviceAddress,
    flags: u32,
};

pub const apis = [_]vk.ApiInfo{
    vk.features.version_1_1,
    vk.extensions.khr_ray_tracing_pipeline,
    vk.extensions.khr_acceleration_structure,
    vk.extensions.khr_buffer_device_address,
};

pub const extensions = [_][*:0]const u8{
    vk.extensions.khr_ray_tracing_pipeline.name,
    vk.extensions.khr_spirv_1_4.name,
    vk.extensions.khr_shader_float_controls.name,
    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_buffer_device_address.name,
    vk.extensions.ext_descriptor_indexing.name,
    vk.extensions.khr_deferred_host_operations.name,
    vk.extensions.ext_scalar_block_layout.name,
};

pub const features = .{
    vk.PhysicalDeviceFeatures{
        .shader_int_16 = vk.TRUE,
        .shader_int_64 = vk.TRUE,
    },
    vk.PhysicalDeviceVulkan11Features{
        .storage_buffer_16_bit_access = vk.TRUE,
    },
    vk.PhysicalDeviceVulkan12Features{
        .buffer_device_address = vk.TRUE,
        .runtime_descriptor_array = vk.TRUE,
        .descriptor_indexing = vk.TRUE,
        .scalar_block_layout = vk.TRUE,
    },
    vk.PhysicalDeviceAccelerationStructureFeaturesKHR{ .acceleration_structure = vk.TRUE },
    vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{ .ray_tracing_pipeline = vk.TRUE },
};

arena: std.heap.ArenaAllocator,

blas_acceleration_structure_buffer: Buffer,
blas_acceleration_structures: []const vk.AccelerationStructureKHR,
blas_acceleration_structure_addresses: []const vk.DeviceAddress,

tlas: Tlas,
triangle_buffer: Buffer,
primitives: Buffer,
materials: Buffer,

images: []const Image,

storage_image: Image,
pipeline: RayTracingPipeline,

pub fn init(
    gc: *const GraphicsContext,
    extent: vk.Extent2D,
    format: vk.Format,
    pool: vk.CommandPool,
    allocator: std.mem.Allocator,
    scene_path: []const u8,
    num_samples: u32,
    num_bounces: u32,
) !Self {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const scene = try Scene.load(scene_path, allocator);
    defer scene.deinit();

    const blases_and_buffer = try createBlases(
        gc,
        &scene,
        pool,
        allocator,
        arena_allocator,
    );
    errdefer {
        for (blases_and_buffer.acceleration_structures) |as| {
            gc.device.destroyAccelerationStructureKHR(as, null);
        }
        blases_and_buffer.acceleration_structure_buffer.deinit(gc);
        blases_and_buffer.triangle_buffer.deinit(gc);
        blases_and_buffer.primitives.deinit(gc);
    }

    const tlas = try Tlas.init(
        gc,
        pool,
        blases_and_buffer.acceleration_structure_addresses,
        &scene,
        allocator,
    );
    errdefer tlas.deinit(gc);

    const images = try createImages(
        gc,
        pool,
        scene.textures,
        arena_allocator,
    );
    errdefer for (images) |image| image.deinit(gc);

    const materials = try Buffer.initAndUpload(
        gc,
        Scene.Material,
        scene.materials,
        .{ .storage_buffer_bit = true },
        .{ .device_local_bit = true },
        .{},
        pool,
    );
    errdefer materials.deinit(gc);

    var storage_image = try Image.init(
        gc,
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
    errdefer storage_image.deinit(gc);
    try storage_image.transistionLayout(gc, pool, .undefined, .general);

    const pipeline = try RayTracingPipeline.init(
        gc,
        &tlas,
        storage_image.view,
        blases_and_buffer.primitives.buffer,
        materials.buffer,
        images,
        num_samples,
        num_bounces,
        pool,
        allocator,
    );
    errdefer pipeline.deinit(gc);

    return .{
        .arena = arena,

        .blas_acceleration_structure_buffer = blases_and_buffer.acceleration_structure_buffer,
        .blas_acceleration_structures = blases_and_buffer.acceleration_structures,
        .blas_acceleration_structure_addresses = blases_and_buffer.acceleration_structure_addresses,
        .triangle_buffer = blases_and_buffer.triangle_buffer,
        .tlas = tlas,
        .primitives = blases_and_buffer.primitives,
        .images = images,
        .materials = materials,

        .storage_image = storage_image,
        .pipeline = pipeline,
    };
}

pub fn deinit(self: *Self, gc: *const GraphicsContext) void {
    self.pipeline.deinit(gc);
    self.storage_image.deinit(gc);

    self.materials.deinit(gc);
    self.primitives.deinit(gc);

    self.tlas.deinit(gc);

    for (self.blas_acceleration_structures) |as| {
        gc.device.destroyAccelerationStructureKHR(as, null);
    }

    self.blas_acceleration_structure_buffer.deinit(gc);

    self.triangle_buffer.deinit(gc);

    for (self.images) |t| t.deinit(gc);

    self.arena.deinit();
}

fn createBlases(
    gc: *const GraphicsContext,
    scene: *const Scene,
    pool: vk.CommandPool,
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
) !struct {
    primitives: Buffer,
    triangle_buffer: Buffer,
    acceleration_structure_buffer: Buffer,
    acceleration_structures: []vk.AccelerationStructureKHR,
    acceleration_structure_addresses: []vk.DeviceAddress,
} {
    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();
    const tmp_arena_allocator = tmp_arena.allocator();

    const triangle_buffer = try Buffer.initAndUpload(
        gc,
        u8,
        scene.triangle_data,
        .{
            .acceleration_structure_build_input_read_only_bit_khr = true,
            .shader_device_address_bit = true,
            .storage_buffer_bit = true,
        },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
        pool,
    );
    errdefer triangle_buffer.deinit(gc);

    const triangle_buffer_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = triangle_buffer.buffer });

    var acceleration_structure_index: usize = 0;
    const acceleration_structures = try arena_allocator.alloc(vk.AccelerationStructureKHR, scene.meshes.len);
    errdefer for (
        acceleration_structures[0..acceleration_structure_index],
    ) |as| gc.device.destroyAccelerationStructureKHR(
        as,
        null,
    );

    const acceleration_structure_addresses = try arena_allocator.alloc(vk.DeviceAddress, scene.meshes.len);

    const build_infos = try tmp_arena_allocator.alloc(vk.AccelerationStructureBuildGeometryInfoKHR, scene.meshes.len);
    const size_infos = try tmp_arena_allocator.alloc(vk.AccelerationStructureBuildSizesInfoKHR, scene.meshes.len);
    const mesh_range_infos = try tmp_arena_allocator.alloc([*]vk.AccelerationStructureBuildRangeInfoKHR, scene.meshes.len);

    var total_acceleration_structures_size: vk.DeviceSize = 0;
    var total_scratch_size: vk.DeviceSize = 0;

    const primitives = try tmp_arena_allocator.alloc(Primitive, scene.primitives.len);
    for (
        scene.meshes,
        build_infos,
        size_infos,
        mesh_range_infos,
    ) |
        mesh,
        *build_info,
        *size_info,
        *mesh_range_info,
    | {
        const scene_primitives = scene.primitives[mesh.start..mesh.end];

        const geometires = try tmp_arena_allocator.alloc(
            vk.AccelerationStructureGeometryKHR,
            scene_primitives.len,
        );
        const range_infos = try tmp_arena_allocator.alloc(
            vk.AccelerationStructureBuildRangeInfoKHR,
            scene_primitives.len,
        );
        const triangle_counts = try tmp_arena_allocator.alloc(
            u32,
            scene_primitives.len,
        );
        mesh_range_info.* = range_infos.ptr;
        for (
            scene_primitives,
            geometires,
            range_infos,
            triangle_counts,
            primitives[mesh.start..mesh.end],
        ) |
            scene_primitive,
            *geometry,
            *range_info,
            *triangle_count,
            *primitive,
        | {
            geometry.* = .{
                .geometry_type = .triangles_khr,
                .flags = .{ .opaque_bit_khr = true },
                .geometry = .{
                    .triangles = .{
                        .vertex_format = .r32g32b32_sfloat,
                        .vertex_stride = @sizeOf([3]f32),
                        .max_vertex = scene_primitive.max_vertex,
                        .vertex_data = .{ .device_address = triangle_buffer_address + scene_primitive.positions_offset },
                        .index_type = if (scene_primitive.info.uint32_indices) .uint32 else .uint16,
                        .index_data = .{ .device_address = triangle_buffer_address + scene_primitive.indices_offset },
                        .transform_data = .{ .device_address = 0 },
                    },
                },
            };

            range_info.* = .{
                .primitive_count = scene_primitive.triangle_count,
                .primitive_offset = 0,
                .first_vertex = 0,
                .transform_offset = 0,
            };

            primitive.* = .{
                .index_address = triangle_buffer_address + scene_primitive.indices_offset,
                .normal_address = triangle_buffer_address + scene_primitive.normals_offset,
                .tangent_address = triangle_buffer_address + scene_primitive.tangents_offset,
                .uv_address = triangle_buffer_address + scene_primitive.uvs_offset,
                .flags = @bitCast(Primitive.Flags{
                    .material_index = scene_primitive.info.material_index,
                    .uin32_indices = scene_primitive.info.uint32_indices,
                }),
            };

            triangle_count.* = scene_primitive.triangle_count;
        }

        build_info.* = .{
            .type = .bottom_level_khr,
            .flags = .{ .prefer_fast_trace_bit_khr = true },
            .mode = .build_khr,
            .geometry_count = @intCast(geometires.len),
            .p_geometries = geometires.ptr,
            .scratch_data = .{ .device_address = 0 },
        };
        size_info.* = .{
            .acceleration_structure_size = 0,
            .update_scratch_size = 0,
            .build_scratch_size = 0,
        };

        gc.device.getAccelerationStructureBuildSizesKHR(
            .device_khr,
            build_info,
            triangle_counts.ptr,
            size_info,
        );

        total_acceleration_structures_size += std.mem.alignForward(
            u64,
            size_info.acceleration_structure_size,
            256,
        );
        total_scratch_size += size_info.build_scratch_size;
    }

    const acceleration_structures_buffer = try Buffer.init(
        gc,
        total_acceleration_structures_size,
        .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    errdefer acceleration_structures_buffer.deinit(gc);

    const scratch_buffer = try Buffer.init(
        gc,
        total_scratch_size,
        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    defer scratch_buffer.deinit(gc);

    {
        var scratch_buffer_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = scratch_buffer.buffer });
        var acceleration_structure_offset: vk.DeviceSize = 0;
        for (
            acceleration_structures,
            acceleration_structure_addresses,
            build_infos,
            size_infos,
        ) |
            *as,
            *as_address,
            *build_info,
            *size_info,
        | {
            as.* = try gc.device.createAccelerationStructureKHR(&.{
                .buffer = acceleration_structures_buffer.buffer,
                .offset = acceleration_structure_offset,
                .size = size_info.acceleration_structure_size,
                .type = .bottom_level_khr,
            }, null);
            acceleration_structure_offset += std.mem.alignForward(
                u64,
                size_info.acceleration_structure_size,
                256,
            );

            as_address.* = gc.device.getAccelerationStructureDeviceAddressKHR(&.{
                .acceleration_structure = as.*,
            });

            build_info.dst_acceleration_structure = as.*;
            build_info.scratch_data = .{ .device_address = scratch_buffer_address };
            scratch_buffer_address += size_info.build_scratch_size;

            acceleration_structure_index += 1;
        }
    }

    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.device.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.device.freeCommandBuffers(pool, 1, @ptrCast(&cmdbuf));

    try gc.device.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    gc.device.cmdBuildAccelerationStructuresKHR(
        cmdbuf,
        @intCast(build_infos.len),
        build_infos.ptr,
        mesh_range_infos.ptr,
    );
    try gc.device.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.device.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.device.queueWaitIdle(gc.graphics_queue.handle);

    const primitives_buffer = try Buffer.initAndUpload(
        gc,
        Primitive,
        primitives,
        .{
            .shader_device_address_bit = true,
            .storage_buffer_bit = true,
        },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
        pool,
    );
    errdefer primitives_buffer.deinit(gc);

    return .{
        .primitives = primitives_buffer,
        .triangle_buffer = triangle_buffer,
        .acceleration_structure_buffer = acceleration_structures_buffer,
        .acceleration_structures = acceleration_structures,
        .acceleration_structure_addresses = acceleration_structure_addresses,
    };
}

fn createImages(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    textures: []const Scene.Texture,
    arena_allocator: std.mem.Allocator,
) ![]const Image {
    var image_index: usize = 0;
    const images = try arena_allocator.alloc(Image, textures.len);
    errdefer for (images[0..image_index]) |*image| image.deinit(gc);

    for (textures, images) |texture, *image| {
        image.* = try Image.initAndUpload(
            gc,
            texture.data,
            .{ .width = texture.width, .height = texture.height },
            .r8g8b8a8_unorm,
            .{ .sampled_bit = true },
            .optimal,
            .undefined,
            .{ .device_local_bit = true },
            .{},
            pool,
        );

        image_index += 1;
    }

    return images;
}

pub fn record(
    self: *const Self,
    gc: *const GraphicsContext,
    dst_image: vk.Image,
    extent: vk.Extent2D,
    cmdbuf: vk.CommandBuffer,
    camera: Camera,
    frame_count: u32,
) !void {
    Image.imageSetLayout(
        gc,
        cmdbuf,
        dst_image,
        .undefined,
        .transfer_dst_optimal,
    );

    defer Image.imageSetLayout(
        gc,
        cmdbuf,
        dst_image,
        .transfer_dst_optimal,
        .present_src_khr,
    );

    const callable_shader_entry = vk.StridedDeviceAddressRegionKHR{
        .device_address = 0,
        .stride = 0,
        .size = 0,
    };

    gc.device.cmdBindPipeline(cmdbuf, .ray_tracing_khr, self.pipeline.pipeline);
    gc.device.cmdBindDescriptorSets(
        cmdbuf,
        .ray_tracing_khr,
        self.pipeline.pipeline_layout,
        0,
        1,
        @ptrCast(&self.pipeline.descriptor_set),
        0,
        undefined,
    );

    const push_constants = RayTracingPipeline.PushConstants{
        .position = camera.position.toVec4(1.0),
        .horizontal = camera.horizontal.toVec4(0.0),
        .vertical = camera.vertical.toVec4(0.0),
        .forward = camera.forward.toVec4(0.0),
        .frame_count = frame_count,
    };

    gc.device.cmdPushConstants(
        cmdbuf,
        self.pipeline.pipeline_layout,
        .{ .raygen_bit_khr = true },
        0,
        @sizeOf(RayTracingPipeline.PushConstants),
        @ptrCast(&push_constants),
    );

    gc.device.cmdTraceRaysKHR(
        cmdbuf,
        &self.pipeline.ray_gen_device_region,
        &self.pipeline.miss_device_region,
        &self.pipeline.closest_hit_device_region,
        &callable_shader_entry,
        extent.width,
        extent.height,
        1,
    );

    // Copy from storage image to destination image
    self.storage_image.setLayout(
        gc,
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
    gc.device.cmdCopyImage(
        cmdbuf,
        self.storage_image.image,
        .transfer_src_optimal,
        dst_image,
        .transfer_dst_optimal,
        1,
        @ptrCast(&image_copy),
    );

    self.storage_image.setLayout(
        gc,
        cmdbuf,
        .transfer_src_optimal,
        .general,
    );
}

pub fn resize(
    self: *Self,
    gc: *const GraphicsContext,
    extent: vk.Extent2D,
    format: vk.Format,
    pool: vk.CommandPool,
) !void {
    self.storage_image.deinit(gc);
    self.storage_image = try Image.init(
        gc,
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
    try self.storage_image.transistionLayout(gc, pool, .undefined, .general);

    self.pipeline.updateImageDescriptor(
        gc,
        self.storage_image.view,
    );
}
