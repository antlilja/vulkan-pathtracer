const std = @import("std");
const vk = @import("vulkan");

const Self = @This();

const apis: []const vk.ApiInfo = &.{.{
    .base_commands = .{
        .createInstance = true,
        .getInstanceProcAddr = true,
    },
    .instance_commands = .{
        .destroyInstance = true,
        .createDevice = true,
        .createXcbSurfaceKHR = true,
        .destroySurfaceKHR = true,
        .enumeratePhysicalDevices = true,
        .getPhysicalDeviceProperties = true,
        .getPhysicalDeviceProperties2 = true,
        .enumerateDeviceExtensionProperties = true,
        .getPhysicalDeviceSurfaceFormatsKHR = true,
        .getPhysicalDeviceSurfacePresentModesKHR = true,
        .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
        .getPhysicalDeviceQueueFamilyProperties = true,
        .getPhysicalDeviceSurfaceSupportKHR = true,
        .getPhysicalDeviceMemoryProperties = true,
        .getDeviceProcAddr = true,
    },
}};

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);

const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

vkb: BaseDispatch,
vki: InstanceDispatch,
instance: vk.Instance,

pub fn init(
    name: [*:0]const u8,
    get_instance_proc_addr: vk.PfnGetInstanceProcAddr,
    required_extensions: []const [*:0]const u8,
) !Self {
    var self: Self = undefined;

    self.vkb = try BaseDispatch.load(get_instance_proc_addr);

    const app_info = vk.ApplicationInfo{
        .p_application_name = name,
        .application_version = vk.makeApiVersion(1, 0, 0, 0),
        .p_engine_name = name,
        .engine_version = vk.makeApiVersion(1, 0, 0, 0),
        .api_version = vk.API_VERSION_1_3,
    };

    self.instance = try self.vkb.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(required_extensions.len),
        .pp_enabled_extension_names = required_extensions.ptr,
        .enabled_layer_count = validation_layers.len,
        .pp_enabled_layer_names = &validation_layers,
    }, null);

    self.vki = try InstanceDispatch.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr);
    errdefer self.vki.destroyInstance(self.instance, null);

    return self;
}

pub fn deinit(self: *Self) void {
    self.vki.destroyInstance(self.instance, null);
}
