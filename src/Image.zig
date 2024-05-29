const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

const Buffer = @import("Buffer.zig");

const Self = @This();

image: vk.Image,
memory: vk.DeviceMemory,

view: vk.ImageView,

pub fn init(
    device: *const Device,
    extent: vk.Extent2D,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    tiling: vk.ImageTiling,
    initial_layout: vk.ImageLayout,
    memory_property_flags: vk.MemoryPropertyFlags,
    memory_allocate_flags: vk.MemoryAllocateFlags,
) !Self {
    const image = try device.vkd.createImage(device.device, &.{
        .image_type = .@"2d",
        .extent = .{
            .width = extent.width,
            .height = extent.height,
            .depth = 1,
        },
        .format = format,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .usage = usage,
        .initial_layout = initial_layout,
        .sharing_mode = .exclusive,
        .tiling = tiling,
    }, null);
    errdefer device.vkd.destroyImage(device.device, image, null);

    const memory_allocate_flags_info = vk.MemoryAllocateFlagsInfo{
        .flags = memory_allocate_flags,
        .device_mask = 0,
    };

    const mem_reqs = device.vkd.getImageMemoryRequirements(device.device, image);
    const memory = try device.vkd.allocateMemory(device.device, &.{
        .p_next = @as(*const anyopaque, @ptrCast(&memory_allocate_flags_info)),
        .allocation_size = mem_reqs.size,
        .memory_type_index = try device.findMemoryTypeIndex(mem_reqs.memory_type_bits, memory_property_flags),
    }, null);
    errdefer device.vkd.freeMemory(device.device, memory, null);
    try device.vkd.bindImageMemory(device.device, image, memory, 0);

    const view = try device.vkd.createImageView(device.device, &.{
        .view_type = .@"2d",
        .format = format,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .components = .{
            .r = .r,
            .g = .g,
            .b = .b,
            .a = .a,
        },
    }, null);
    errdefer device.vkd.destroyImageView(device.device, view, null);

    return .{
        .image = image,
        .memory = memory,
        .view = view,
    };
}

pub fn initAndUpload(
    device: *const Device,
    image_data: []const u8,
    extent: vk.Extent2D,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    tiling: vk.ImageTiling,
    initial_layout: vk.ImageLayout,
    memory_property_flags: vk.MemoryPropertyFlags,
    memory_allocate_flags: vk.MemoryAllocateFlags,
    pool: vk.CommandPool,
) !Self {
    var usage_upload = usage;
    usage_upload.transfer_dst_bit = true;

    // Upload data to staging_buffer
    const self = try Self.init(
        device,
        extent,
        format,
        usage,
        tiling,
        initial_layout,
        memory_property_flags,
        memory_allocate_flags,
    );
    errdefer self.deinit(device);

    try self.transistionLayout(device, pool, .undefined, .transfer_dst_optimal);

    const staging_buffer = try Buffer.initAndStore(
        device,
        u8,
        image_data,
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

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{
                .color_bit = true,
            },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{
            .width = extent.width,
            .height = extent.height,
            .depth = 1,
        },
    };

    device.vkd.cmdCopyBufferToImage(
        cmdbuf,
        staging_buffer.buffer,
        self.image,
        vk.ImageLayout.transfer_dst_optimal,
        1,
        @ptrCast(&region),
    );

    try device.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try device.vkd.queueSubmit(device.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try device.vkd.queueWaitIdle(device.graphics_queue.handle);

    try self.transistionLayout(device, pool, .transfer_dst_optimal, .shader_read_only_optimal);

    return self;
}

pub fn deinit(self: *const Self, device: *const Device) void {
    device.vkd.destroyImageView(device.device, self.view, null);
    device.vkd.destroyImage(device.device, self.image, null);
    device.vkd.freeMemory(device.device, self.memory, null);
}

pub fn transistionLayout(
    self: *const Self,
    device: *const Device,
    pool: vk.CommandPool,
    from: vk.ImageLayout,
    to: vk.ImageLayout,
) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try device.vkd.allocateCommandBuffers(device.device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @as([*]vk.CommandBuffer, @ptrCast(&cmdbuf)));
    defer device.vkd.freeCommandBuffers(device.device, pool, 1, @ptrCast(&cmdbuf));

    try device.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    const barrier = vk.ImageMemoryBarrier{
        .old_layout = from,
        .new_layout = to,
        .src_queue_family_index = ~@as(u32, 0),
        .dst_queue_family_index = ~@as(u32, 0),
        .image = self.image,
        .src_access_mask = .{},
        .dst_access_mask = .{},
        .subresource_range = .{
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
            .aspect_mask = .{ .color_bit = true },
        },
    };

    device.vkd.cmdPipelineBarrier(
        cmdbuf,
        .{ .top_of_pipe_bit = true },
        .{ .bottom_of_pipe_bit = true },
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&barrier),
    );

    try device.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .p_wait_dst_stage_mask = undefined,
    };
    try device.vkd.queueSubmit(device.graphics_queue.handle, 1, @ptrCast(&si), .null_handle);
    try device.vkd.queueWaitIdle(device.graphics_queue.handle);
}

pub fn setLayout(
    self: *const Self,
    device: *const Device,
    cmdbuf: vk.CommandBuffer,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) void {
    imageSetLayout(
        device,
        cmdbuf,
        self.image,
        old_layout,
        new_layout,
    );
}

pub fn imageSetLayout(
    device: *const Device,
    cmdbuf: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) void {
    const barrier = vk.ImageMemoryBarrier{
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = ~@as(u32, 0),
        .dst_queue_family_index = ~@as(u32, 0),
        .image = image,
        .src_access_mask = accessFlagsForImageLayout(old_layout),
        .dst_access_mask = accessFlagsForImageLayout(new_layout),
        .subresource_range = .{
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
            .aspect_mask = .{ .color_bit = true },
        },
    };

    device.vkd.cmdPipelineBarrier(
        cmdbuf,
        pipelineStageForLayout(old_layout),
        pipelineStageForLayout(new_layout),
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast(&barrier),
    );
}

fn accessFlagsForImageLayout(layout: vk.ImageLayout) vk.AccessFlags {
    return switch (layout) {
        .preinitialized => .{ .host_write_bit = true },
        .transfer_dst_optimal => .{ .transfer_write_bit = true },
        .transfer_src_optimal => .{ .transfer_read_bit = true },
        .color_attachment_optimal => .{ .color_attachment_write_bit = true },
        .depth_stencil_attachment_optimal => .{ .depth_stencil_attachment_write_bit = true },
        .shader_read_only_optimal => .{ .shader_read_bit = true },
        else => .{},
    };
}

fn pipelineStageForLayout(layout: vk.ImageLayout) vk.PipelineStageFlags {
    return switch (layout) {
        .preinitialized => .{ .host_bit = true },
        .transfer_dst_optimal, .transfer_src_optimal => .{ .transfer_bit = true },
        .color_attachment_optimal => .{ .color_attachment_output_bit = true },
        .depth_stencil_attachment_optimal, .shader_read_only_optimal => .{ .all_commands_bit = true },
        .undefined => .{ .top_of_pipe_bit = true },
        else => .{ .bottom_of_pipe_bit = true },
    };
}
