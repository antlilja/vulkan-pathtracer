const std = @import("std");
const builtin = @import("builtin");

const zw = @import("zig-window");

const vk = @import("vulkan");

const apis = [_]vk.ApiInfo{
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
} ++ @import("root").vk_extra_apis;

const BaseDispatch = vk.BaseWrapper(&apis);
const InstanceDispatch = vk.InstanceWrapper(&apis);
const DeviceDispatch = vk.DeviceWrapper(&apis);

const Instance = vk.InstanceProxy(&apis);
const Device = vk.DeviceProxy(&apis);

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const Self = @This();

allocator: std.mem.Allocator,

vulkan_handle: std.DynLib,

vkb: BaseDispatch,

instance: Instance,
surface: vk.SurfaceKHR,

physical_device: vk.PhysicalDevice,
device_properties: vk.PhysicalDeviceProperties,
device_memory_properties: vk.PhysicalDeviceMemoryProperties,

device: Device,
graphics_queue: Queue,
present_queue: Queue,

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    window: zw.Window,
    api_version: vk.Version,
    required_instance_extensions: []const [*:0]const u8,
    required_device_extensions: []const [*:0]const u8,
    features_ptr: ?*const anyopaque,
    enable_validation: bool,
) !Self {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    var self: Self = undefined;

    self.allocator = allocator;

    self.vulkan_handle = switch (builtin.target.os.tag) {
        .linux => try std.DynLib.open("libvulkan.so.1"),
        .windows => try std.DynLib.open("vulkan-1.dll"),
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.target.os.tag)),
    };
    errdefer self.vulkan_handle.close();

    const get_instance_proc_addr_fn = self.vulkan_handle.lookup(
        vk.PfnGetInstanceProcAddr,
        "vkGetInstanceProcAddr",
    ) orelse return error.FailedToLoadVulkan;

    self.vkb = try BaseDispatch.load(get_instance_proc_addr_fn);

    const app_name_z = try arena_allocator.dupeZ(u8, name);

    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name_z,
        .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .p_engine_name = app_name_z,
        .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
        .api_version = @bitCast(api_version),
    };

    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const supports_validation_layers = blk: {
        var prop_count: u32 = undefined;
        std.debug.assert(try self.vkb.enumerateInstanceLayerProperties(
            &prop_count,
            null,
        ) == .success);

        const props = try arena_allocator.alloc(vk.LayerProperties, @intCast(prop_count));
        std.debug.assert(try self.vkb.enumerateInstanceLayerProperties(
            &prop_count,
            props.ptr,
        ) == .success);

        for (validation_layers) |layer| {
            var found = false;
            const layer_name = std.mem.span(layer);
            for (props) |prop| loop: {
                const prop_layer_name: [*:0]const u8 = @ptrCast(&prop.layer_name);
                if (std.mem.eql(u8, std.mem.span(prop_layer_name), layer_name)) {
                    found = true;
                    break :loop;
                }
            }
            if (!found) break :blk false;
        }
        break :blk true;
    };

    const instance = try self.vkb.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(required_instance_extensions.len),
        .pp_enabled_extension_names = required_instance_extensions.ptr,
        .enabled_layer_count = if (enable_validation and supports_validation_layers) validation_layers.len else 0,
        .pp_enabled_layer_names = &validation_layers,
    }, null);

    const vki = try allocator.create(InstanceDispatch);
    errdefer allocator.destroy(vki);
    vki.* = try InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);
    self.instance = Instance.init(instance, vki);
    errdefer self.instance.destroyInstance(null);

    // Create surface
    self.surface = try window.createVulkanSurface(
        vk.Instance,
        vk.SurfaceKHR,
        self.instance.handle,
        @ptrCast(get_instance_proc_addr_fn),
        null,
    );
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    const device_extensions = try arena_allocator.alloc([*:0]const u8, required_device_extensions.len + 1);
    device_extensions[0] = vk.extensions.khr_swapchain.name;
    for (required_device_extensions, 1..) |ext, i| {
        device_extensions[i] = ext;
    }

    // Pick physical device
    self.physical_device, self.device_properties, const queues = blk: {
        var device_count: u32 = undefined;
        _ = try self.instance.enumeratePhysicalDevices(
            &device_count,
            null,
        );

        const devices = try arena_allocator.alloc(vk.PhysicalDevice, device_count);

        _ = try self.instance.enumeratePhysicalDevices(
            &device_count,
            devices.ptr,
        );

        device_loop: for (devices) |device| {
            // Check for required extension support
            {
                var count: u32 = undefined;
                _ = try self.instance.enumerateDeviceExtensionProperties(
                    device,
                    null,
                    &count,
                    null,
                );

                const propsv = try arena_allocator.alloc(vk.ExtensionProperties, count);

                _ = try self.instance.enumerateDeviceExtensionProperties(
                    device,
                    null,
                    &count,
                    propsv.ptr,
                );

                for (required_device_extensions) |ext| {
                    for (propsv) |props| {
                        if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                            break;
                        }
                    } else {
                        continue :device_loop;
                    }
                }
            }

            // Check for surface support
            {
                var format_count: u32 = undefined;
                _ = try self.instance.getPhysicalDeviceSurfaceFormatsKHR(
                    device,
                    self.surface,
                    &format_count,
                    null,
                );

                var present_mode_count: u32 = undefined;
                _ = try self.instance.getPhysicalDeviceSurfacePresentModesKHR(
                    device,
                    self.surface,
                    &present_mode_count,
                    null,
                );

                if (format_count == 0 or present_mode_count == 0) continue;
            }

            var family_count: u32 = undefined;
            self.instance.getPhysicalDeviceQueueFamilyProperties(
                device,
                &family_count,
                null,
            );

            const families = try arena_allocator.alloc(vk.QueueFamilyProperties, family_count);
            self.instance.getPhysicalDeviceQueueFamilyProperties(
                device,
                &family_count,
                families.ptr,
            );

            var graphics_family: ?u32 = null;
            var present_family: ?u32 = null;

            for (families, 0..) |properties, i| {
                const family: u32 = @intCast(i);

                if (graphics_family == null and properties.queue_flags.graphics_bit) {
                    graphics_family = family;
                }

                if (present_family == null and (try self.instance.getPhysicalDeviceSurfaceSupportKHR(
                    device,
                    family,
                    self.surface,
                )) == vk.TRUE) {
                    present_family = family;
                }
            }

            if (graphics_family == null or present_family == null) continue;

            const props = self.instance.getPhysicalDeviceProperties(device);
            break :blk .{
                device,
                props,
                .{
                    .graphics_family = graphics_family.?,
                    .present_family = present_family.?,
                },
            };
        }

        return error.NoSuitableDevice;
    };

    const device = blk: {
        const priority = [_]f32{1};
        const qci = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = queues.graphics_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
            .{
                .queue_family_index = queues.present_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        const queue_count: u32 = if (queues.graphics_family == queues.present_family)
            1
        else
            2;

        break :blk try self.instance.createDevice(self.physical_device, &.{
            .p_next = features_ptr,
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &qci,
            .enabled_extension_count = @intCast(device_extensions.len),
            .pp_enabled_extension_names = device_extensions.ptr,
        }, null);
    };

    const vkd = try allocator.create(DeviceDispatch);
    errdefer allocator.destroy(vkd);
    vkd.* = try DeviceDispatch.load(device, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
    self.device = Device.init(device, vkd);
    errdefer self.device.destroyDevice(null);

    self.graphics_queue = Queue.init(self.device, queues.graphics_family);
    self.present_queue = Queue.init(self.device, queues.present_family);

    self.device_memory_properties = self.instance.getPhysicalDeviceMemoryProperties(self.physical_device);

    return self;
}

pub fn deinit(self: *Self) void {
    self.device.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);

    self.allocator.destroy(self.device.wrapper);
    self.allocator.destroy(self.instance.wrapper);

    self.vulkan_handle.close();
}

pub fn findMemoryTypeIndex(self: Self, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.device_memory_properties.memory_types[0..self.device_memory_properties.memory_type_count], 0..) |mem_type, i| {
        if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn allocate(self: Self, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.device.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
    }, null);
}
