const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");
const Buffer = @import("Buffer.zig");

const Self = @This();

handle: vk.AccelerationStructureKHR,
buffer: Buffer,
address: vk.DeviceAddress,

pub fn init(
    device: *const Device,
    pool: vk.CommandPool,
    position_address: vk.DeviceAddress,
    index_address: vk.DeviceAddress,
    num_triangles: u32,
    max_vertex: u32,
) !Self {
    const geom = vk.AccelerationStructureGeometryKHR{
        .geometry_type = .triangles_khr,
        .flags = .{ .opaque_bit_khr = true },
        .geometry = .{
            .triangles = .{
                .vertex_format = .r32g32b32_sfloat,
                .vertex_stride = @sizeOf([4]f32),
                .max_vertex = max_vertex,
                .vertex_data = .{ .device_address = position_address },
                .index_type = .uint32,
                .index_data = .{ .device_address = index_address },
                .transform_data = .{ .device_address = 0 },
            },
        },
    };

    var build_info = vk.AccelerationStructureBuildGeometryInfoKHR{
        .type = .bottom_level_khr,
        .flags = .{ .prefer_fast_trace_bit_khr = true },
        .mode = .build_khr,
        .geometry_count = 1,
        .p_geometries = @ptrCast(&geom),
        .scratch_data = .{ .device_address = 0 },
    };

    var build_sizes: vk.AccelerationStructureBuildSizesInfoKHR = .{
        .acceleration_structure_size = 0,
        .update_scratch_size = 0,
        .build_scratch_size = 0,
    };
    device.vkd.getAccelerationStructureBuildSizesKHR(
        device.device,
        .device_khr,
        &build_info,
        @ptrCast(&num_triangles),
        &build_sizes,
    );

    const buffer = try Buffer.init(
        device,
        build_sizes.acceleration_structure_size,
        .{ .acceleration_structure_storage_bit_khr = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    errdefer buffer.deinit(device);

    const acceleration_structure = try device.vkd.createAccelerationStructureKHR(device.device, &.{
        .buffer = buffer.buffer,
        .offset = 0,
        .size = build_sizes.acceleration_structure_size,
        .type = .bottom_level_khr,
    }, null);
    errdefer device.vkd.destroyAccelerationStructureKHR(
        device.device,
        acceleration_structure,
        null,
    );

    const address = device.vkd.getAccelerationStructureDeviceAddressKHR(device.device, &.{
        .acceleration_structure = acceleration_structure,
    });

    const scratch_buffer = try Buffer.init(
        device,
        build_sizes.build_scratch_size,
        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
        .{ .device_local_bit = true },
        .{ .device_address_bit = true },
    );
    defer scratch_buffer.deinit(device);
    const scratch_buffer_address = device.vkd.getBufferDeviceAddress(device.device, &.{ .buffer = scratch_buffer.buffer });

    build_info.dst_acceleration_structure = acceleration_structure;
    build_info.scratch_data = .{ .device_address = scratch_buffer_address };

    const build_range_info = vk.AccelerationStructureBuildRangeInfoKHR{
        .primitive_count = num_triangles,
        .primitive_offset = 0,
        .first_vertex = 0,
        .transform_offset = 0,
    };

    var cmdbuf: vk.CommandBuffer = undefined;
    try device.vkd.allocateCommandBuffers(device.device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer device.vkd.freeCommandBuffers(device.device, pool, 1, @ptrCast(&cmdbuf));

    try device.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const build_range_infos = [_][*]const vk.AccelerationStructureBuildRangeInfoKHR{
        @ptrCast(&build_range_info),
    };

    device.vkd.cmdBuildAccelerationStructuresKHR(
        cmdbuf,
        1,
        @ptrCast(&build_info),
        @ptrCast(&build_range_infos),
    );
    try device.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try device.vkd.queueSubmit(device.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try device.vkd.queueWaitIdle(device.graphics_queue.handle);

    return .{
        .handle = acceleration_structure,
        .buffer = buffer,
        .address = address,
    };
}

pub fn deinit(self: *const Self, device: *const Device) void {
    device.vkd.destroyAccelerationStructureKHR(
        device.device,
        self.handle,
        null,
    );
    self.buffer.deinit(device);
}
