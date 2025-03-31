const std = @import("std");
const vk = @import("vulkan");
const Nuklear = @import("Nuklear.zig");
const nk = Nuklear.nk;

const shaders = @import("shaders");

const vert_shader align(@alignOf(u32)) = @embedFile("nuklear_vert").*;
const frag_shader align(@alignOf(u32)) = @embedFile("nuklear_frag").*;

const GraphicsContext = @import("GraphicsContext.zig");
const Buffer = @import("Buffer.zig");
const Image = @import("Image.zig");

const Vertex = struct {
    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "uv"),
        },
        .{
            .binding = 0,
            .location = 2,
            .format = .r8g8b8a8_uint,
            .offset = @offsetOf(Vertex, "color"),
        },
    };

    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

const Self = @This();

pub const apis = [_]vk.ApiInfo{};
pub const extensions = [_][*:0]const u8{};
pub const features = .{};

pipeline: vk.Pipeline,
pipeline_layout: vk.PipelineLayout,

descriptor_pool: vk.DescriptorPool,
descriptor_set_layout: vk.DescriptorSetLayout,
descriptor_sets: []vk.DescriptorSet,

textures: []Image,

sampler: vk.Sampler,

vertex_buffer: Buffer,
index_buffer: Buffer,

max_vertex_buffer_size: u32,
max_index_buffer_size: u32,

pub fn init(
    gc: *const GraphicsContext,
    pool: vk.CommandPool,
    render_pass: vk.RenderPass,
    max_vertex_buffer_size: u32,
    max_index_buffer_size: u32,
    nuklear: *const Nuklear,
    allocator: std.mem.Allocator,
) !Self {
    const textures = blk: {
        const data: u32 = 0xffffffff;
        const null_image = try Image.initAndUpload(
            gc,
            std.mem.asBytes(&data),
            .{
                .width = 1,
                .height = 1,
            },
            .r8g8b8a8_unorm,
            .{ .sampled_bit = true },
            .optimal,
            .undefined,
            .{ .device_local_bit = true },
            .{},
            pool,
        );
        errdefer null_image.deinit(gc);

        const font_image = try Image.initAndUpload(
            gc,
            nuklear.font_atlas_data,
            .{
                .width = nuklear.font_atlas_width,
                .height = nuklear.font_atlas_height,
            },
            .r8g8b8a8_unorm,
            .{ .sampled_bit = true },
            .optimal,
            .undefined,
            .{ .device_local_bit = true },
            .{},
            pool,
        );
        errdefer font_image.deinit(gc);

        const textures = try allocator.alloc(Image, 2);
        textures[0] = null_image;
        textures[1] = font_image;

        break :blk textures;
    };
    errdefer {
        for (textures) |texture| {
            texture.deinit(gc);
        }
    }

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

    const descriptor_pool = blk: {
        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .combined_image_sampler, .descriptor_count = @intCast(textures.len) },
        };

        break :blk try gc.device.createDescriptorPool(&.{
            .max_sets = @intCast(textures.len),
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = @as([*]const vk.DescriptorPoolSize, @ptrCast(&pool_sizes)),
        }, null);
    };
    errdefer gc.device.destroyDescriptorPool(
        descriptor_pool,
        null,
    );

    const descriptor_set_layout = blk: {
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .stage_flags = .{ .fragment_bit = true },
            },
        };

        break :blk try gc.device.createDescriptorSetLayout(&.{
            .binding_count = bindings.len,
            .p_bindings = @as([*]const vk.DescriptorSetLayoutBinding, @ptrCast(&bindings)),
        }, null);
    };
    errdefer gc.device.destroyDescriptorSetLayout(
        descriptor_set_layout,
        null,
    );

    const descriptor_sets = try allocator.alloc(vk.DescriptorSet, 2);
    errdefer allocator.free(descriptor_sets);
    {
        const descriptor_set_layouts = try allocator.alloc(vk.DescriptorSetLayout, textures.len);
        defer allocator.free(descriptor_set_layouts);
        for (descriptor_set_layouts) |*layout| {
            layout.* = descriptor_set_layout;
        }

        try gc.device.allocateDescriptorSets(&.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = @intCast(descriptor_sets.len),
            .p_set_layouts = descriptor_set_layouts.ptr,
        }, @ptrCast(descriptor_sets.ptr));
    }

    // Write to descriptor sets
    {
        const infos = try allocator.alloc(vk.DescriptorImageInfo, textures.len);
        defer allocator.free(infos);

        const write_descriptors = try allocator.alloc(vk.WriteDescriptorSet, textures.len);
        defer allocator.free(write_descriptors);

        for (infos, write_descriptors, descriptor_sets, textures) |*info, *write, ds, texture| {
            info.* = .{
                .sampler = sampler,
                .image_view = texture.view,
                .image_layout = .shader_read_only_optimal,
            };

            write.* = .{
                .p_image_info = @ptrCast(info),
                .dst_set = ds,
                .dst_binding = 0,
                .descriptor_count = 1,
                .descriptor_type = .combined_image_sampler,
                .dst_array_element = 0,
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            };
        }

        gc.device.updateDescriptorSets(
            @intCast(write_descriptors.len),
            write_descriptors.ptr,
            0,
            undefined,
        );
    }

    const pipeline, const pipeline_layout = blk: {
        const push_constant_range = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = 64,
        };

        const pipeline_layout = try gc.device.createPipelineLayout(&.{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_constant_range),
        }, null);
        errdefer gc.device.destroyPipelineLayout(pipeline_layout, null);

        const vert = try gc.device.createShaderModule(&.{
            .code_size = vert_shader.len,
            .p_code = @ptrCast(&vert_shader),
        }, null);
        defer gc.device.destroyShaderModule(vert, null);

        const frag = try gc.device.createShaderModule(&.{
            .code_size = frag_shader.len,
            .p_code = @ptrCast(&frag_shader),
        }, null);
        defer gc.device.destroyShaderModule(frag, null);

        const pssci = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = "main",
            },
            .{
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = "main",
            },
        };

        const pvisci = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
            .vertex_attribute_description_count = Vertex.attribute_description.len,
            .p_vertex_attribute_descriptions = &Vertex.attribute_description,
        };

        const piasci = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        };

        const pvsci = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
            .scissor_count = 1,
            .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
        };

        const prsci = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };

        const pmsci = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = vk.FALSE,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        const pcbas = vk.PipelineColorBlendAttachmentState{
            .blend_enable = vk.TRUE,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .src_alpha,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = .{
                .r_bit = true,
                .g_bit = true,
                .b_bit = true,
                .a_bit = true,
            },
        };

        const pcbsci = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&pcbas),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };

        const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
        const pdsci = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        };

        const gpci = vk.GraphicsPipelineCreateInfo{
            .flags = .{},
            .stage_count = 2,
            .p_stages = &pssci,
            .p_vertex_input_state = &pvisci,
            .p_input_assembly_state = &piasci,
            .p_tessellation_state = null,
            .p_viewport_state = &pvsci,
            .p_rasterization_state = &prsci,
            .p_multisample_state = &pmsci,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &pcbsci,
            .p_dynamic_state = &pdsci,
            .layout = pipeline_layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try gc.device.createGraphicsPipelines(
            .null_handle,
            1,
            @ptrCast(&gpci),
            null,
            @ptrCast(&pipeline),
        );

        break :blk .{ pipeline, pipeline_layout };
    };
    errdefer {
        gc.device.destroyPipeline(pipeline, null);
        gc.device.destroyPipelineLayout(pipeline_layout, null);
    }

    const vertex_buffer = try Buffer.init(
        gc,
        max_vertex_buffer_size,
        .{ .vertex_buffer_bit = true },
        .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
        .{},
    );
    errdefer vertex_buffer.deinit(gc);

    const index_buffer = try Buffer.init(
        gc,
        max_index_buffer_size,
        .{ .index_buffer_bit = true },
        .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        },
        .{},
    );
    errdefer index_buffer.deinit(gc);

    return .{
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .descriptor_pool = descriptor_pool,
        .descriptor_set_layout = descriptor_set_layout,
        .descriptor_sets = descriptor_sets,

        .textures = textures,
        .sampler = sampler,

        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,

        .max_vertex_buffer_size = max_vertex_buffer_size,
        .max_index_buffer_size = max_index_buffer_size,
    };
}

pub fn deinit(self: *const Self, gc: *const GraphicsContext, allocator: std.mem.Allocator) void {
    self.index_buffer.deinit(gc);
    self.vertex_buffer.deinit(gc);

    gc.device.destroyPipeline(self.pipeline, null);
    gc.device.destroyPipelineLayout(self.pipeline_layout, null);

    allocator.free(self.descriptor_sets);
    gc.device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
    gc.device.destroyDescriptorPool(self.descriptor_pool, null);
    gc.device.destroySampler(self.sampler, null);

    for (self.textures) |texture| {
        texture.deinit(gc);
    }
    allocator.free(self.textures);
}

pub fn record(
    self: *Self,
    gc: *const GraphicsContext,
    cmdbuf: vk.CommandBuffer,
    extent: vk.Extent2D,
    nuklear: *Nuklear,
) !void {
    {
        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(extent.width),
            .height = @floatFromInt(extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        gc.device.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
        gc.device.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));
    }

    var cmd_it = blk: {
        const vertex_memory: [*]u8 = @ptrCast(try gc.device.mapMemory(
            self.vertex_buffer.memory,
            0,
            vk.WHOLE_SIZE,
            .{},
        ));
        defer gc.device.unmapMemory(self.vertex_buffer.memory);

        const index_memory: [*]u8 = @ptrCast(try gc.device.mapMemory(
            self.index_buffer.memory,
            0,
            vk.WHOLE_SIZE,
            .{},
        ));
        defer gc.device.unmapMemory(self.index_buffer.memory);

        break :blk nuklear.getDrawCommands(
            Vertex,
            vertex_memory[0..self.max_vertex_buffer_size],
            index_memory[0..self.max_index_buffer_size],
        );
    };

    gc.device.cmdBindPipeline(cmdbuf, .graphics, self.pipeline);

    const offset: vk.DeviceSize = 0;
    gc.device.cmdBindVertexBuffers(
        cmdbuf,
        0,
        1,
        @ptrCast(&self.vertex_buffer.buffer),
        @ptrCast(&offset),
    );

    gc.device.cmdBindIndexBuffer(
        cmdbuf,
        self.index_buffer.buffer,
        0,
        .uint16,
    );

    const matrix = [16]f32{
        2.0 / @as(f32, @floatFromInt(extent.width)), 0.0,                                           0.0,  0.0,
        0.0,                                         -2.0 / @as(f32, @floatFromInt(extent.height)), 0.0,  0.0,
        0.0,                                         0.0,                                           -1.0, 0.0,
        -1.0,                                        1.0,                                           0.0,  1.0,
    };

    gc.device.cmdPushConstants(
        cmdbuf,
        self.pipeline_layout,
        .{ .vertex_bit = true },
        0,
        @sizeOf([16]f32),
        @ptrCast(&matrix),
    );

    var current_texture_id: u32 = std.math.maxInt(c_int);
    var index_offset: u32 = 0;
    while (cmd_it.next(nuklear)) |cmd| {
        if (cmd.texture_id != current_texture_id) {
            current_texture_id = cmd.texture_id;

            gc.device.cmdBindDescriptorSets(
                cmdbuf,
                .graphics,
                self.pipeline_layout,
                0,
                1,
                @ptrCast(&self.descriptor_sets[current_texture_id]),
                0,
                null,
            );
        }
        if (cmd.count == 0) continue;

        const scissor = vk.Rect2D{
            .offset = .{
                .x = @intFromFloat(@max(cmd.clip_rect.x, 0.0)),
                .y = @intFromFloat(@max(cmd.clip_rect.y, 0.0)),
            },
            .extent = .{
                .width = @intFromFloat(cmd.clip_rect.w),
                .height = @intFromFloat(cmd.clip_rect.h),
            },
        };
        gc.device.cmdSetScissor(
            cmdbuf,
            0,
            1,
            @ptrCast(&scissor),
        );
        gc.device.cmdDrawIndexed(
            cmdbuf,
            cmd.count,
            1,
            index_offset,
            0,
            0,
        );
        index_offset += cmd.count;
    }
}
