const std = @import("std");
const vk = @import("vulkan");
const shaders = @import("shaders");

const GraphicsContext = @import("GraphicsContext.zig");

const Tlas = @import("Tlas.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");

const Self = @This();

sampler: vk.Sampler,

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
    gc: *const GraphicsContext,
    tlas: *const Tlas,
    image_view: vk.ImageView,
    obj_desc_buffer: vk.Buffer,
    material_buffer: vk.Buffer,
    images: []const Image,
    num_samples: u32,
    num_bounces: u32,
    allocator: std.mem.Allocator,
) !Self {
    const sampler = try gc.device.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0.0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .mipmap_mode = .linear,
        .mip_lod_bias = 0.0,
        .min_lod = 0.0,
        .max_lod = 0.0,
    }, null);
    errdefer gc.device.destroySampler(sampler, null);

    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .acceleration_structure_khr, .descriptor_count = 1 },
        .{ .type = .storage_image, .descriptor_count = 1 },
        .{ .type = .storage_buffer, .descriptor_count = 2 },
        .{ .type = .combined_image_sampler, .descriptor_count = 1 },
    };

    const descriptor_pool = try gc.device.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = pool_sizes.len,
        .p_pool_sizes = @as([*]const vk.DescriptorPoolSize, @ptrCast(&pool_sizes)),
    }, null);
    errdefer gc.device.destroyDescriptorPool(descriptor_pool, null);

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
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
        .{
            .binding = 4,
            .descriptor_count = @intCast(images.len),
            .descriptor_type = .combined_image_sampler,
            .stage_flags = .{ .closest_hit_bit_khr = true },
        },
    };

    const descriptor_set_layout = try gc.device.createDescriptorSetLayout(&.{
        .binding_count = bindings.len,
        .p_bindings = @as([*]const vk.DescriptorSetLayoutBinding, @ptrCast(&bindings)),
    }, null);
    errdefer gc.device.destroyDescriptorSetLayout(descriptor_set_layout, null);

    var descriptor_set: vk.DescriptorSet = undefined;
    try gc.device.allocateDescriptorSets(&.{
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

        const material_buffer_info = vk.DescriptorBufferInfo{
            .buffer = material_buffer,
            .offset = 0,
            .range = ~@as(usize, 0),
        };

        const image_infos = try allocator.alloc(vk.DescriptorImageInfo, images.len);
        defer allocator.free(image_infos);

        for (images, image_infos) |image, *info| {
            info.* = .{
                .image_view = image.view,
                .sampler = sampler,
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
                .p_buffer_info = @ptrCast(&material_buffer_info),
                .dst_set = descriptor_set,
                .dst_binding = 3,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .dst_array_element = 0,
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .p_image_info = @ptrCast(image_infos),
                .dst_set = descriptor_set,
                .dst_binding = 4,
                .descriptor_count = @intCast(image_infos.len),
                .descriptor_type = .combined_image_sampler,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };

        gc.device.updateDescriptorSets(
            write_descriptors.len,
            &write_descriptors,
            0,
            undefined,
        );
    }

    const push_constant_range = vk.PushConstantRange{
        .stage_flags = .{ .raygen_bit_khr = true },
        .offset = 0,
        .size = 128,
    };
    const pipeline_layout = try gc.device.createPipelineLayout(&.{
        .flags = .{},
        .set_layout_count = 1,
        .p_set_layouts = @as([*]const vk.DescriptorSetLayout, @ptrCast(&descriptor_set_layout)),
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @as([*]const vk.PushConstantRange, @ptrCast(&push_constant_range)),
    }, null);
    errdefer gc.device.destroyPipelineLayout(pipeline_layout, null);

    const ray_gen = try gc.device.createShaderModule(&.{
        .code_size = shaders.ray_gen.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.ray_gen)),
    }, null);
    defer gc.device.destroyShaderModule(ray_gen, null);

    const miss = try gc.device.createShaderModule(&.{
        .code_size = shaders.miss.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.miss)),
    }, null);
    defer gc.device.destroyShaderModule(miss, null);

    const closest_hit = try gc.device.createShaderModule(&.{
        .code_size = shaders.closest_hit.len,
        .p_code = @as([*]const u32, @ptrCast(&shaders.closest_hit)),
    }, null);
    defer gc.device.destroyShaderModule(closest_hit, null);

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
    _ = try gc.device.createRayTracingPipelinesKHR(
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

        gc.instance.getPhysicalDeviceProperties2(gc.physical_device, &physical_device_properties2);
    }

    const handle_size = ray_tracing_pipeline_properties.shader_group_handle_size;
    const handle_size_aligned = std.mem.alignForward(
        u32,
        ray_tracing_pipeline_properties.shader_group_handle_size,
        ray_tracing_pipeline_properties.shader_group_handle_alignment,
    );

    const handle_storage = try allocator.alloc(u8, handle_size_aligned * shader_groups.len);
    defer allocator.free(handle_storage);

    try gc.device.getRayTracingShaderGroupHandlesKHR(
        pipeline,
        0,
        shader_groups.len,
        shader_groups.len * handle_size_aligned,
        @ptrCast(handle_storage.ptr),
    );

    const ray_gen_binding_table = try Buffer.initAndStore(
        gc,
        u8,
        handle_storage[0..handle_size],
        .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
        .{},
        .{ .device_address_bit = true },
    );

    const miss_binding_table = try Buffer.initAndStore(
        gc,
        u8,
        handle_storage[handle_size_aligned..(handle_size_aligned + handle_size)],
        .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
        .{},
        .{ .device_address_bit = true },
    );

    const closest_hit_binding_table = try Buffer.initAndStore(
        gc,
        u8,
        handle_storage[(handle_size_aligned * 2)..(handle_size_aligned * 2 + handle_size)],
        .{ .shader_binding_table_bit_khr = true, .shader_device_address_bit = true },
        .{},
        .{ .device_address_bit = true },
    );

    const ray_gen_device_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = ray_gen_binding_table.buffer });
    const miss_device_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = miss_binding_table.buffer });
    const closest_hit_device_address = gc.device.getBufferDeviceAddressKHR(&.{ .buffer = closest_hit_binding_table.buffer });

    return .{
        .sampler = sampler,
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

pub fn deinit(self: *const Self, gc: *const GraphicsContext) void {
    self.closest_hit_binding_table.deinit(gc);
    self.miss_binding_table.deinit(gc);
    self.ray_gen_binding_table.deinit(gc);
    gc.device.destroyPipeline(self.pipeline, null);
    gc.device.destroyPipelineLayout(self.pipeline_layout, null);
    gc.device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    gc.device.destroyDescriptorPool(self.descriptor_pool, null);
    gc.device.destroySampler(self.sampler, null);
}

pub fn updateImageDescriptor(self: *const Self, gc: *const GraphicsContext, image_view: vk.ImageView) void {
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

    gc.device.updateDescriptorSets(
        write_descriptors.len,
        &write_descriptors,
        0,
        undefined,
    );
}
