const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

const Self = @This();

buffer: vk.Buffer,
memory: vk.DeviceMemory,

pub fn init(
    device: *const Device,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    memory_proerty_flags: vk.MemoryPropertyFlags,
    memory_allocate_flags: vk.MemoryAllocateFlags,
) !Self {
    const buffer = try device.vkd.createBuffer(device.device, &.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.vkd.destroyBuffer(device.device, buffer, null);

    const memory_allocate_flags_info = vk.MemoryAllocateFlagsInfo{
        .flags = memory_allocate_flags,
        .device_mask = 0,
    };

    const mem_reqs = device.vkd.getBufferMemoryRequirements(device.device, buffer);
    const memory = try device.vkd.allocateMemory(device.device, &.{
        .p_next = @as(*const anyopaque, @ptrCast(&memory_allocate_flags_info)),
        .allocation_size = mem_reqs.size,
        .memory_type_index = try device.findMemoryTypeIndex(mem_reqs.memory_type_bits, memory_proerty_flags),
    }, null);
    errdefer device.vkd.freeMemory(device.device, memory, null);
    try device.vkd.bindBufferMemory(device.device, buffer, memory, 0);

    return .{
        .buffer = buffer,
        .memory = memory,
    };
}

pub fn deinit(self: *const Self, device: *const Device) void {
    device.vkd.destroyBuffer(device.device, self.buffer, null);
    device.vkd.freeMemory(device.device, self.memory, null);
}

pub fn oneTimeCopyFrom(
    self: Self,
    from: Self,
    device: *const Device,
    pool: vk.CommandPool,
    size: u64,
) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try device.vkd.allocateCommandBuffers(device.device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer device.vkd.freeCommandBuffers(
        device.device,
        pool,
        1,
        @ptrCast(&cmdbuf),
    );

    try device.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    device.vkd.cmdCopyBuffer(
        cmdbuf,
        from.buffer,
        self.buffer,
        1,
        @ptrCast(&region),
    );

    try device.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try device.vkd.queueSubmit(
        device.graphics_queue.handle,
        1,
        @ptrCast(&si),
        .null_handle,
    );
    try device.vkd.queueWaitIdle(device.graphics_queue.handle);
}

pub fn initAndStore(
    device: *const Device,
    comptime Type: type,
    arr: []const Type,
    usage: vk.BufferUsageFlags,
    memory_property_flags: vk.MemoryPropertyFlags,
    memory_allocate_flags: vk.MemoryAllocateFlags,
) !Self {
    const size = @sizeOf(Type) * arr.len;

    var property_flags = memory_property_flags;
    property_flags.host_visible_bit = true;
    property_flags.host_coherent_bit = true;

    const self = try Self.init(
        device,
        size,
        usage,
        property_flags,
        memory_allocate_flags,
    );
    errdefer self.deinit(device);

    const data = try device.vkd.mapMemory(
        device.device,
        self.memory,
        0,
        vk.WHOLE_SIZE,
        .{},
    );
    defer device.vkd.unmapMemory(device.device, self.memory);

    const gpu_arr: [*]Type = @alignCast(@ptrCast(data));
    for (arr, 0..) |e, i| {
        gpu_arr[i] = e;
    }

    return self;
}

pub fn initAndUpload(
    device: *const Device,
    comptime Type: type,
    arr: []const Type,
    usage: vk.BufferUsageFlags,
    memory_property_flags: vk.MemoryPropertyFlags,
    memory_allocate_flags: vk.MemoryAllocateFlags,
    pool: vk.CommandPool,
) !Self {
    const size = @sizeOf(Type) * arr.len;

    var usage_upload = usage;
    usage_upload.transfer_dst_bit = true;

    // Upload data to staging_buffer
    const self = try Self.init(
        device,
        size,
        usage_upload,
        memory_property_flags,
        memory_allocate_flags,
    );
    errdefer self.deinit(device);

    const staging_buffer = try Self.initAndStore(
        device,
        Type,
        arr,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        .{},
    );
    defer staging_buffer.deinit(device);

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

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    device.vkd.cmdCopyBuffer(cmdbuf, staging_buffer.buffer, self.buffer, 1, @ptrCast(&region));

    try device.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try device.vkd.queueSubmit(device.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try device.vkd.queueWaitIdle(device.graphics_queue.handle);

    return self;
}
