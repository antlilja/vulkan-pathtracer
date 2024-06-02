const std = @import("std");
const vk = @import("vulkan");
const Instance = @import("Instance.zig");

const Self = @This();

const apis: []const vk.ApiInfo = &.{.{
    .device_commands = .{
        .destroyDevice = true,
        .getDeviceQueue = true,
        .createSemaphore = true,
        .createFence = true,
        .createImage = true,
        .destroyImage = true,
        .createImageView = true,
        .destroyImageView = true,
        .destroySemaphore = true,
        .destroyFence = true,
        .createSampler = true,
        .destroySampler = true,
        .getSwapchainImagesKHR = true,
        .createSwapchainKHR = true,
        .destroySwapchainKHR = true,
        .acquireNextImageKHR = true,
        .deviceWaitIdle = true,
        .waitForFences = true,
        .resetFences = true,
        .queueSubmit = true,
        .queuePresentKHR = true,
        .createCommandPool = true,
        .destroyCommandPool = true,
        .allocateCommandBuffers = true,
        .freeCommandBuffers = true,
        .queueWaitIdle = true,
        .createShaderModule = true,
        .destroyShaderModule = true,
        .createPipelineLayout = true,
        .destroyPipelineLayout = true,
        .createRenderPass = true,
        .destroyRenderPass = true,
        .createGraphicsPipelines = true,
        .destroyPipeline = true,
        .createFramebuffer = true,
        .destroyFramebuffer = true,
        .createAccelerationStructureKHR = true,
        .destroyAccelerationStructureKHR = true,
        .createDescriptorPool = true,
        .destroyDescriptorPool = true,
        .createDescriptorSetLayout = true,
        .destroyDescriptorSetLayout = true,
        .allocateDescriptorSets = true,
        .freeDescriptorSets = true,
        .updateDescriptorSets = true,
        .beginCommandBuffer = true,
        .endCommandBuffer = true,
        .allocateMemory = true,
        .freeMemory = true,
        .createBuffer = true,
        .destroyBuffer = true,
        .createRayTracingPipelinesKHR = true,
        .createComputePipelines = true,
        .getBufferMemoryRequirements = true,
        .getImageMemoryRequirements = true,
        .getBufferDeviceAddress = true,
        .getAccelerationStructureBuildSizesKHR = true,
        .getAccelerationStructureDeviceAddressKHR = true,
        .getRayTracingShaderGroupHandlesKHR = true,
        .mapMemory = true,
        .unmapMemory = true,
        .bindBufferMemory = true,
        .bindImageMemory = true,
        .cmdBeginRenderPass = true,
        .cmdEndRenderPass = true,
        .cmdBindPipeline = true,
        .cmdDrawIndexed = true,
        .cmdSetViewport = true,
        .cmdSetScissor = true,
        .cmdBindVertexBuffers = true,
        .cmdBindIndexBuffer = true,
        .cmdCopyBuffer = true,
        .cmdCopyBufferToImage = true,
        .cmdPushConstants = true,
        .cmdBuildAccelerationStructuresKHR = true,
        .cmdPipelineBarrier = true,
        .cmdBindDescriptorSets = true,
        .cmdTraceRaysKHR = true,
        .cmdCopyImage = true,
        .cmdDispatch = true,

        .cmdBeginRendering = true,
        .cmdEndRendering = true,
    },
}};

const DeviceDispatch = vk.DeviceWrapper(apis);

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: DeviceDispatch, dev: vk.Device, family: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,

    vk.extensions.khr_ray_tracing_pipeline.name,
    vk.extensions.khr_spirv_1_4.name,
    vk.extensions.khr_shader_float_controls.name,

    vk.extensions.khr_acceleration_structure.name,
    vk.extensions.khr_buffer_device_address.name,
    vk.extensions.ext_descriptor_indexing.name,
    vk.extensions.khr_deferred_host_operations.name,

    vk.extensions.khr_dynamic_rendering.name,
};

vkd: DeviceDispatch,

physical_device: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,

device: vk.Device,
graphics_queue: Queue,
present_queue: Queue,

pub fn init(instance: *const Instance, surface: vk.SurfaceKHR, allocator: std.mem.Allocator) !Self {
    var self: Self = undefined;
    const candidate = try pickPhysicalDevice(instance, allocator, surface);
    self.physical_device = candidate.pdev;
    self.props = candidate.props;
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    var buffer_address_features = vk.PhysicalDeviceBufferDeviceAddressFeatures{
        .buffer_device_address = vk.TRUE,
    };
    var ray_tracing_pipeline_features = vk.PhysicalDeviceRayTracingPipelineFeaturesKHR{
        .p_next = @ptrCast(&buffer_address_features),
        .ray_tracing_pipeline = vk.TRUE,
    };
    var acceleration_structure_features = vk.PhysicalDeviceAccelerationStructureFeaturesKHR{
        .p_next = @ptrCast(&ray_tracing_pipeline_features),
        .acceleration_structure = vk.TRUE,
    };

    var runtime_descriptor_array_feature = vk.PhysicalDeviceDescriptorIndexingFeatures{
        .p_next = @ptrCast(&acceleration_structure_features),
        .runtime_descriptor_array = vk.TRUE,
    };

    var dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
        .p_next = @ptrCast(&runtime_descriptor_array_feature),
        .dynamic_rendering = vk.TRUE,
    };

    const device_features = vk.PhysicalDeviceFeatures{
        .shader_int_64 = vk.TRUE,
    };

    self.device = try instance.vki.createDevice(candidate.pdev, &.{
        .p_next = @as(*const anyopaque, @ptrCast(&dynamic_rendering_features)),
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @as([*]const [*:0]const u8, @ptrCast(&required_device_extensions)),
        .p_enabled_features = &device_features,
    }, null);
    self.vkd = try DeviceDispatch.load(self.device, instance.vki.dispatch.vkGetDeviceProcAddr);
    errdefer self.vkd.destroyDevice(self.dev, null);

    self.graphics_queue = Queue.init(self.vkd, self.device, candidate.queues.graphics_family);
    self.present_queue = Queue.init(self.vkd, self.device, candidate.queues.present_family);

    self.mem_props = instance.vki.getPhysicalDeviceMemoryProperties(self.physical_device);

    return self;
}

pub fn deinit(self: *const Self) void {
    self.vkd.destroyDevice(self.device, null);
}

pub fn getName(self: *const Self) []const u8 {
    const len = std.mem.indexOfScalar(u8, &self.props.device_name, 0).?;
    return self.props.device_name[0..len];
}

pub fn findMemoryTypeIndex(self: Self, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (memory_type_bits & (@as(u32, 1) << @as(u5, @truncate(i))) != 0 and mem_type.property_flags.contains(flags)) {
            return @as(u32, @truncate(i));
        }
    }

    return error.NoSuitableMemoryType;
}

fn pickPhysicalDevice(
    instance: *const Instance,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    var device_count: u32 = undefined;
    _ = try instance.vki.enumeratePhysicalDevices(instance.instance, &device_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(pdevs);

    _ = try instance.vki.enumeratePhysicalDevices(instance.instance, &device_count, pdevs.ptr);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: *const Instance,
    pdev: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    const props = instance.vki.getPhysicalDeviceProperties(pdev);

    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(
    instance: *const Instance,
    pdev: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
    surface: vk.SurfaceKHR,
) !?QueueAllocation {
    var family_count: u32 = undefined;
    instance.vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    instance.vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: *const Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: *const Instance,
    pdev: vk.PhysicalDevice,
    allocator: std.mem.Allocator,
) !bool {
    var count: u32 = undefined;
    _ = try instance.vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

    const propsv = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(propsv);

    _ = try instance.vki.enumerateDeviceExtensionProperties(pdev, null, &count, propsv.ptr);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            const len = std.mem.indexOfScalar(u8, &props.extension_name, 0).?;
            const prop_ext_name = props.extension_name[0..len];
            if (std.mem.eql(u8, std.mem.span(ext), prop_ext_name)) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}
