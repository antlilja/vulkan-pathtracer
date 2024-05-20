const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const TLAS = @import("TLAS.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");
const Texture = @import("Texture.zig");

const Self = @This();

descriptor_pool: vk.DescriptorPool,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_set: vk.DescriptorSet,

pipeline_layout: vk.PipelineLayout,
pipeline: vk.Pipeline,
properties: vk.PhysicalDeviceRayTracingPipelinePropertiesKHR,

ray_gen_binding_table: Buffer,
miss_binding_table: Buffer,
closest_hit_binding_table: Buffer,

ray_gen_device_address: vk.DeviceAddress,
miss_device_address: vk.DeviceAddress,
closest_hit_device_address: vk.DeviceAddress,

pub fn init(
    instance: *const Instance,
    device: *const Device,
    tlas: *const TLAS,
    image_view: vk.ImageView,
    obj_desc_buffer: vk.Buffer,
    albedos: []const Texture,
    metal_roughness: []const Texture,
    emissive: []const Texture,
    normals: []const Texture,
    num_samples: u32,
    num_bounces: u32,
    allocator: std.mem.Allocator,
) !Self {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .acceleration_structure_khr, .descriptor_count = 1 },
        .{ .type = .storage_image, .descriptor_count = 1 },
        .{ .type = .storage_buffer, .descriptor_count = 4 },
    };

    const descriptor_pool = try device.vkd.createDescriptorPool(device.device, &.{
        .max_sets = 1,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @as([*]const vk.DescriptorPoolSize, @ptrCast(&pool_sizes)),
    }, null);
    errdefer device.vkd.destroyDescriptorPool(device.device, descriptor_pool, null);

    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_count = 1,
            .descriptor_type = .acceleration_structure_khr,
            .stage_flags = .{ .raygen_bit_khr = true, .closest_hit_bit_khr = true },
        },
        .{
            .binding = 1,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .stage_flags = .{ .raygen_bit_khr = true },
        },
        .{
            .binding = 2,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
        .{
            .binding = 3,
            .descriptor_count = @intCast(albedos.len),
            .descriptor_type = .combined_image_sampler,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
        .{
            .binding = 4,
            .descriptor_count = @intCast(metal_roughness.len),
            .descriptor_type = .combined_image_sampler,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
        .{
            .binding = 5,
            .descriptor_count = @intCast(emissive.len),
            .descriptor_type = .combined_image_sampler,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
        .{
            .binding = 6,
            .descriptor_count = @intCast(normals.len),
            .descriptor_type = .combined_image_sampler,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
    };

    const descriptor_set_layout = try device.vkd.createDescriptorSetLayout(device.device, &.{
        .binding_count = bindings.len,
        .p_bindings = @as([*]const vk.DescriptorSetLayoutBinding, @ptrCast(&bindings)),
    }, null);
    errdefer device.vkd.destroyDescriptorSetLayout(device.device, descriptor_set_layout, null);

    var descriptor_set: vk.DescriptorSet = undefined;
    try device.vkd.allocateDescriptorSets(device.device, &.{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&descriptor_set_layout)),
    }, @ptrCast(&descriptor_set));

    {
        const acceleration_structure_descriptor_info = vk.WriteDescriptorSetAccelerationStructureKHR{
            .acceleration_structure_count = 1,
            .p_acceleration_structures = @ptrCast(&tlas.handle),
        };

        const image_descriptor_info = vk.DescriptorImageInfo{
            .sampler = .null_handle,
            .image_view = image_view,
            .image_layout = .general,
        };

        const obj_desc_buffer_info = vk.DescriptorBufferInfo{
            .buffer = obj_desc_buffer,
            .offset = 0,
            .range = ~@as(usize, 0),
        };

        const albedo_image_info = try allocator.alloc(vk.DescriptorImageInfo, albedos.len);
        defer allocator.free(albedo_image_info);

        for (albedos, albedo_image_info) |texture, *info| {
            info.* = .{
                .image_view = texture.image.view,
                .sampler = texture.sampler,
                .image_layout = .shader_read_only_optimal,
            };
        }

        const metal_roughness_image_info = try allocator.alloc(vk.DescriptorImageInfo, metal_roughness.len);
        defer allocator.free(metal_roughness_image_info);

        for (metal_roughness, metal_roughness_image_info) |texture, *info| {
            info.* = .{
                .image_view = texture.image.view,
                .sampler = texture.sampler,
                .image_layout = .shader_read_only_optimal,
            };
        }

        const emissive_image_info = try allocator.alloc(vk.DescriptorImageInfo, emissive.len);
        defer allocator.free(emissive_image_info);

        for (emissive, emissive_image_info) |texture, *info| {
            info.* = .{
                .image_view = texture.image.view,
                .sampler = texture.sampler,
                .image_layout = .shader_read_only_optimal,
            };
        }

        const normal_image_info = try allocator.alloc(vk.DescriptorImageInfo, normals.len);
        defer allocator.free(normal_image_info);

        for (normals, normal_image_info) |texture, *info| {
            info.* = .{
                .image_view = texture.image.view,
                .sampler = texture.sampler,
                .image_layout = .shader_read_only_optimal,
            };
        }

        const write_descriptors = [_]vk.WriteDescriptorSet{
            .{
                .p_next = @ptrCast(&acceleration_structure_descriptor_info),
                .dst_set = descriptor_set,
                .dst_binding = 0,
                .descriptor_count = 1,
                .descriptor_type = .acceleration_structure_khr,
                .dst_array_element = 0,
                .p_image_info = undefined,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_image_info = @ptrCast(&image_descriptor_info),
                .dst_set = descriptor_set,
                .dst_binding = 1,
                .descriptor_count = 1,
                .descriptor_type = .storage_image,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_buffer_info = @ptrCast(&obj_desc_buffer_info),
                .dst_set = descriptor_set,
                .dst_binding = 2,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .dst_array_element = 0,
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_image_info = @ptrCast(albedo_image_info),
                .dst_set = descriptor_set,
                .dst_binding = 3,
                .descriptor_count = @intCast(albedo_image_info.len),
                .descriptor_type = .combined_image_sampler,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_image_info = @ptrCast(metal_roughness_image_info),
                .dst_set = descriptor_set,
                .dst_binding = 4,
                .descriptor_count = @intCast(metal_roughness_image_info.len),
                .descriptor_type = .combined_image_sampler,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_image_info = @ptrCast(emissive_image_info),
                .dst_set = descriptor_set,
                .dst_binding = 5,
                .descriptor_count = @intCast(emissive_image_info.len),
                .descriptor_type = .combined_image_sampler,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_image_info = @ptrCast(normal_image_info),
                .dst_set = descriptor_set,
                .dst_binding = 6,
                .descriptor_count = @intCast(normal_image_info.len),
                .descriptor_type = .combined_image_sampler,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };

        device.vkd.updateDescriptorSets(
            device.device,
            write_descriptors.len,
            &write_descriptors,
            0,
            undefined,
        );
    }

    const push_constant_range = vk.PushConstantRange{
        .stage_flags = .{
            .raygen_bit_khr = true,
            .closest_hit_bit_khr = true,
        },
        .offset = 0,
        .size = 128,
    };
    const pipeline_layout = try device.vkd.createPipelineLayout(device.device, &.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&descriptor_set_layout)),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @as([*]const vk.PushConstantRange, @ptrCast(&push_constant_range)),
    }, null);
    errdefer device.vkd.destroyPipelineLayout(device.device, pipeline_layout, null);

    const ray_gen = try device.vkd.createShaderModule(device.device, &.{
        .code_size = shaders.ray_gen.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.ray_gen)),
    }, null);
    defer device.vkd.destroyShaderModule(device.device, ray_gen, null);

    const miss = try device.vkd.createShaderModule(device.device, &.{
        .code_size = shaders.miss.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.miss)),
    }, null);
    defer device.vkd.destroyShaderModule(device.device, miss, null);

    const closest_hit = try device.vkd.createShaderModule(device.device, &.{
        .code_size = shaders.closest_hit.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.closest_hit)),
    }, null);
    defer device.vkd.destroyShaderModule(device.device, closest_hit, null);

    const shader_groups = [_]vk.RayTracingShaderGroupCreateInfoKHR{
        .{
            .type = .general_khr,
            .general_shader = 0,
            .closest_hit_shader = ~@as(u32, 0),
            .any_hit_shader = ~@as(u32, 0),
            .intersection_shader = ~@as(u32, 0),
        },
        .{
            .type = .general_khr,
            .general_shader = 1,
            .closest_hit_shader = ~@as(u32, 0),
            .any_hit_shader = ~@as(u32, 0),
            .intersection_shader = ~@as(u32, 0),
        },
        .{
            .type = .triangles_hit_group_khr,
            .general_shader = ~@as(u32, 0),
            .closest_hit_shader = 2,
            .any_hit_shader = ~@as(u32, 0),
            .intersection_shader = ~@as(u32, 0),
        },
    };

    const specialization = vk.SpecializationMapEntry{
        .constant_id = 0,
        .offset = 0,
        .size = @sizeOf(u32),
    };

    const shaders_stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .raygen_bit_khr = true },
            .module = ray_gen,
            .p_name = "main",
            .p_specialization_info = &.{
                .map_entry_count = 1,
                .p_map_entries = @as([*]const vk.SpecializationMapEntry, @ptrCast(&specialization)),
                .data_size = @sizeOf(u32),
                .p_data = @as(*const anyopaque, @ptrCast(&num_samples)),
            },
        },
        .{
            .stage = .{ .miss_bit_khr = true },
            .module = miss,
            .p_name = "main",
        },
        .{
            .stage = .{ .closest_hit_bit_khr = true },
            .module = closest_hit,
            .p_name = "main",
            .p_specialization_info = &.{
                .map_entry_count = 1,
                .p_map_entries = @as([*]const vk.SpecializationMapEntry, @ptrCast(&specialization)),
                .data_size = @sizeOf(u32),
                .p_data = @as(*const anyopaque, @ptrCast(&num_bounces)),
            },
        },
    };

    const create_info = vk.RayTracingPipelineCreateInfoKHR{
        .stage_count = shaders_stages.len,
        .p_stages = &shaders_stages,
        .group_count = shader_groups.len,
        .p_groups = &shader_groups,
        .max_pipeline_ray_recursion_depth = 4,
        .layout = pipeline_layout,
        .base_pipeline_index = 0,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try device.vkd.createRayTracingPipelinesKHR(
        device.device,
        .null_handle,
        .null_handle,
        1,
        @ptrCast(&create_info),
        null,
        @ptrCast(&pipeline),
    );

    var ray_tracing_pipeline_properties = vk.PhysicalDeviceRayTracingPipelinePropertiesKHR{
        .shader_group_handle_size = 0,
        .max_ray_recursion_depth = 0,
        .max_shader_group_stride = 0,
        .shader_group_base_alignment = 0,
        .shader_group_handle_capture_replay_size = 0,
        .max_ray_dispatch_invocation_count = 0,
        .shader_group_handle_alignment = 0,
        .max_ray_hit_attribute_size = 0,
    };
    {
        var physical_device_properties2 = vk.PhysicalDeviceProperties2{
            .p_next = @as(*anyopaque, @ptrCast(&ray_tracing_pipeline_properties)),
            .properties = undefined,
        };

        instance.vki.getPhysicalDeviceProperties2(device.physical_device, &physical_device_properties2);
    }

    const handle_size = ray_tracing_pipeline_properties.shader_group_handle_size;
    const handle_size_aligned = std.mem.alignForward(
        u32,
        ray_tracing_pipeline_properties.shader_group_handle_size,
        ray_tracing_pipeline_properties.shader_group_handle_alignment,
    );

    const handle_storage = try allocator.alloc(u8, handle_size_aligned * shader_groups.len);
    defer allocator.free(handle_storage);

    try device.vkd.getRayTracingShaderGroupHandlesKHR(
        device.device,
        pipeline,
        0,
        shader_groups.len,
        shader_groups.len * handle_size_aligned,
        @ptrCast(handle_storage.ptr),
    );

    const ray_gen_binding_table = try Buffer.initAndStore(
        device,
        u8,
        handle_storage[0..handle_size],
        .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
        .{},
        .{ .device_address_bit = true },
    );

    const miss_binding_table = try Buffer.initAndStore(
        device,
        u8,
        handle_storage[handle_size_aligned..(handle_size_aligned + handle_size)],
        .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
        .{},
        .{ .device_address_bit = true },
    );

    const closest_hit_binding_table = try Buffer.initAndStore(
        device,
        u8,
        handle_storage[(handle_size_aligned * 2)..(handle_size_aligned * 2 + handle_size)],
        .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
        .{},
        .{ .device_address_bit = true },
    );

    const ray_gen_device_address = device.vkd.getBufferDeviceAddress(device.device, &.{ .buffer = ray_gen_binding_table.buffer });
    const miss_device_address = device.vkd.getBufferDeviceAddress(device.device, &.{ .buffer = miss_binding_table.buffer });
    const closest_hit_device_address = device.vkd.getBufferDeviceAddress(device.device, &.{ .buffer = closest_hit_binding_table.buffer });

    return .{
        .descriptor_pool = descriptor_pool,
        .descriptor_set = descriptor_set,
        .descriptor_set_layout = descriptor_set_layout,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .properties = ray_tracing_pipeline_properties,
        .ray_gen_binding_table = ray_gen_binding_table,
        .miss_binding_table = miss_binding_table,
        .closest_hit_binding_table = closest_hit_binding_table,

        .ray_gen_device_address = ray_gen_device_address,
        .miss_device_address = miss_device_address,
        .closest_hit_device_address = closest_hit_device_address,
    };
}

pub fn deinit(self: *const Self, device: *const Device) void {
    self.closest_hit_binding_table.deinit(device);
    self.miss_binding_table.deinit(device);
    self.ray_gen_binding_table.deinit(device);
    device.vkd.destroyPipeline(device.device, self.pipeline, null);
    device.vkd.destroyPipelineLayout(device.device, self.pipeline_layout, null);
    device.vkd.destroyDescriptorSetLayout(device.device, self.descriptor_set_layout, null);
    device.vkd.destroyDescriptorPool(device.device, self.descriptor_pool, null);
}

pub fn updateImageDescriptor(self: *const Self, device: *const Device, image_view: vk.ImageView) void {
    const image_descriptor_info = vk.DescriptorImageInfo{
        .sampler = .null_handle,
        .image_view = image_view,
        .image_layout = .general,
    };

    const image_write = vk.WriteDescriptorSet{
        .p_image_info = @ptrCast(&image_descriptor_info),
        .dst_set = self.descriptor_set,
        .dst_binding = 1,
        .descriptor_count = 1,
        .descriptor_type = .storage_image,
        .dst_array_element = 0,
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    const write_descriptors = [_]vk.WriteDescriptorSet{image_write};

    device.vkd.updateDescriptorSets(
        device.device,
        write_descriptors.len,
        &write_descriptors,
        0,
        undefined,
    );
}
