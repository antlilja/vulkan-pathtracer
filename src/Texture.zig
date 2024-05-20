const std = @import("std");
const vk = @import("vulkan");
const Device = @import("Device.zig");

const Image = @import("Image.zig");

const Self = @This();

image: Image,
sampler: vk.Sampler,

pub fn init(
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
    const image = try Image.initAndUpload(
        device,
        image_data,
        extent,
        format,
        usage,
        tiling,
        initial_layout,
        memory_property_flags,
        memory_allocate_flags,
        pool,
    );
    errdefer image.deinit(device);

    const sampler = try device.vkd.createSampler(device.device, &.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0.0,
        // .anisotropy_enable = vk.TRUE,
        // .max_anisotropy = device.props.limits.max_sampler_anisotropy,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .linear,
        .mip_lod_bias = 0.0,
        .min_lod = 0.0,
        .max_lod = 0.0,
    }, null);

    return .{
        .image = image,
        .sampler = sampler,
    };
}

pub fn deinit(self: *const Self, device: *const Device) void {
    device.vkd.destroySampler(device.device, self.sampler, null);
    self.image.deinit(device);
}
