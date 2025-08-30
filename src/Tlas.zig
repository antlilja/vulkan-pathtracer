const std = @import("std");
const vk = @import("vulkan");
const Scene = @import("Scene.zig");

const GraphicsContext = @import("GraphicsContext.zig");

const Buffer = @import("Buffer.zig");

const Self = @This();

handle: vk.AccelerationStructureKHR,
buffer: Buffer,
address: vk.DeviceAddress,

pub fn init(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    blas_addresses: []const vk.DeviceAddress,
    scene: *const Scene,
    allocator: std.mem.Allocator,
) !Self {
    const instances = try allocator.alloc(vk.AccelerationStructureInstanceKHR, scene.instances.len);
    defer allocator.free(instances);

    for (
        scene.instances,
        instances,
    ) |
        blas_instance,
        *instance,
    | {
        instance.* = .{
            .transform = .{
                .matrix = .{
                    blas_instance.transform.data[0],
                    blas_instance.transform.data[1],
                    blas_instance.transform.data[2],
                    // .{ blas_instance.transform.elements[0], blas_instance.transform.elements[1], blas_instance.transform.elements[2], blas_instance.transform.elements[3] },
                    // .{ blas_instance.transform.elements[4], blas_instance.transform.elements[5], blas_instance.transform.elements[6], blas_instance.transform.elements[7] },
                    // .{ blas_instance.transform.elements[8], blas_instance.transform.elements[9], blas_instance.transform.elements[10], blas_instance.transform.elements[11] },
                },
            },
            .instance_custom_index_and_mask = .{
                .instance_custom_index = @intCast(scene.meshes[blas_instance.mesh_index].start),
                .mask = 0xff,
            },
            .instance_shader_binding_table_record_offset_and_flags = .{
                .instance_shader_binding_table_record_offset = 0,
                .flags = 0,
            },
            .acceleration_structure_reference = blas_addresses[blas_instance.mesh_index],
        };
    }

    const instance_buffer = try Buffer.initAndUpload(
        gc,
        vk.AccelerationStructureInstanceKHR,
        instances,
        .{ .shader_device_address_bit = true, .acceleration_structure_build_input_read_only_bit_khr = true },
        .{},
        .{ .device_address_bit = true },
        pool,
    );
    defer instance_buffer.deinit(gc);

    const instance_device_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = instance_buffer.buffer });

    const geom = vk.AccelerationStructureGeometryKHR{
        .geometry_type = .instances_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{
            .instances = .{
                .array_of_pointers = .false,
                .data = .{ .device_address = instance_device_address },
            },
        },
    };

    var build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
        .type = .top_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true },
        .mode = .build_khr,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&geom),
        .scratch_data = .{ .device_address = 0 },
    };

    const primitive_count: u32 = @intCast(blas_addresses.len);
    var build_sizes: vk.AccelerationStructureBuildSizesInfoKHR = .{
        .acceleration_structure_size = 0,
        .update_scratch_size = 0,
        .build_scratch_size = 0,
    };
    gc.device.getAccelerationStructureBuildSizesKHR(
        .device_khr,
        &build_info,
        @ptrCast(&primitive_count),
        &build_sizes,
    );

    const buffer = try Buffer.init(
        gc,
        build_sizes.acceleration_structure_size,
        .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    errdefer buffer.deinit(gc);

    const acceleration_structure = try gc.device.createAccelerationStructureKHR(&.{
        .buffer = buffer.buffer,
        .offset = 0,
        .size = build_sizes.acceleration_structure_size,
        .type = .top_level_khr,
    }, null);
    errdefer gc.device.destroyAccelerationStructureKHR(
        acceleration_structure,
        null,
    );

    const scratch_buffer = try Buffer.init(
        gc,
        build_sizes.build_scratch_size,
        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    defer scratch_buffer.deinit(gc);
    const scratch_buffer_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = scratch_buffer.buffer });

    build_info.dst_acceleration_structure = acceleration_structure;
    build_info.scratch_data = .{ .device_address = scratch_buffer_address };

    const build_range_info = vk.AccelerationStructureBuildRangeInfoKHR{
        .primitive_count = primitive_count,
        .primitive_offset = 0,
        .first_vertex = 0,
        .transform_offset = 0,
    };

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

    const build_range_infos = [_][*]const vk.AccelerationStructureBuildRangeInfoKHR{
        @ptrCast(&build_range_info),
    };

    gc.device.cmdBuildAccelerationStructuresKHR(
        cmdbuf,
        1,
        @ptrCast(&build_info),
        @ptrCast(&build_range_infos),
    );
    try gc.device.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.device.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try gc.device.queueWaitIdle(gc.graphics_queue.handle);

    const address = gc.device.getAccelerationStructureDeviceAddressKHR(&.{
        .acceleration_structure = acceleration_structure,
    });

    return .{
        .handle = acceleration_structure,
        .buffer = buffer,
        .address = address,
    };
}

pub fn deinit(self: *const Self, gc: *const GraphicsContext) void {
    gc.device.destroyAccelerationStructureKHR(
        self.handle,
        null,
    );
    self.buffer.deinit(gc);
}
