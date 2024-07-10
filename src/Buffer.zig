const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("GraphicsContext.zig");

const Self = @This();

buffer: vk.Buffer,
memory: vk.DeviceMemory,

pub fn init(
    gc: *const GraphicsContext,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    memory_proerty_flags: vk.MemoryPropertyFlags,
    memory_allocate_flags: vk.MemoryAllocateFlags,
) !Self {
    const buffer = try gc.device.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer gc.device.destroyBuffer(buffer, null);

    const memory_allocate_flags_info = vk.MemoryAllocateFlagsInfo{
        .flags = memory_allocate_flags,
        .device_mask = 0,
    };

    const mem_reqs = gc.device.getBufferMemoryRequirements(buffer);
    const memory = try gc.device.allocateMemory(&.{
        .p_next = @as(*const anyopaque, @ptrCast(&memory_allocate_flags_info)),
        .allocation_size = mem_reqs.size,
        .memory_type_index = try gc.findMemoryTypeIndex(mem_reqs.memory_type_bits, memory_proerty_flags),
    }, null);
    errdefer gc.device.freeMemory(memory, null);
    try gc.device.bindBufferMemory(buffer, memory, 0);

    return .{
        .buffer = buffer,
        .memory = memory,
    };
}

pub fn deinit(self: *const Self, gc: *const GraphicsContext) void {
    gc.device.destroyBuffer(self.buffer, null);
    gc.device.freeMemory(self.memory, null);
}

pub fn oneTimeCopyFrom(
    self: Self,
    from: Self,
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    size: u64,
) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.device.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.device.freeCommandBuffers(
        pool,
        1,
        @ptrCast(&cmdbuf),
    );

    try gc.device.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    gc.device.cmdCopyBuffer(
        cmdbuf,
        from.buffer,
        self.buffer,
        1,
        @ptrCast(&region),
    );

    try gc.device.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.device.queueSubmit(
        gc.graphics_queue.handle,
        1,
        @ptrCast(&si),
        .null_handle,
    );
    try gc.device.queueWaitIdle(gc.graphics_queue.handle);
}

pub fn initAndStore(
    gc: *const GraphicsContext,
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
        gc,
        size,
        usage,
        property_flags,
        memory_allocate_flags,
    );
    errdefer self.deinit(gc);

    const data = try gc.device.mapMemory(
        self.memory,
        0,
        vk.WHOLE_SIZE,
        .{},
    );
    defer gc.device.unmapMemory(self.memory);

    const gpu_arr: [*]Type = @alignCast(@ptrCast(data));
    for (arr, 0..) |e, i| {
        gpu_arr[i] = e;
    }

    return self;
}

pub fn initAndUpload(
    gc: *const GraphicsContext,
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
        gc,
        size,
        usage_upload,
        memory_property_flags,
        memory_allocate_flags,
    );
    errdefer self.deinit(gc);

    const staging_buffer = try Self.initAndStore(
        gc,
        Type,
        arr,
        .{ .transfer_src_bit = true },
        .{ .host_visible_bit = true, .host_coherent_bit = true },
        .{},
    );
    defer staging_buffer.deinit(gc);

    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.device.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));
    defer gc.device.freeCommandBuffers(
        pool,
        1,
        @ptrCast(&cmdbuf),
    );

    try gc.device.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    gc.device.cmdCopyBuffer(
        cmdbuf,
        staging_buffer.buffer,
        self.buffer,
        1,
        @ptrCast(&region),
    );

    try gc.device.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try gc.device.queueSubmit(
        gc.graphics_queue.handle,
        1,
        @ptrCast(&si),
        .null_handle,
    );
    try gc.device.queueWaitIdle(gc.graphics_queue.handle);

    return self;
}
