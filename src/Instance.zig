const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");

const Self = @This();

const apis: []const vk.ApiInfo = &.{.{
    .base_commands = .{
        .createInstance = true,
        .getInstanceProcAddr = true,
        .enumerateInstanceLayerProperties = true,
    },
    .instance_commands = .{
        .destroyInstance = true,
        .createDevice = true,
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

vulkan_library: *anyopaque,

vkb: BaseDispatch,
vki: InstanceDispatch,
instance: vk.Instance,

pub fn init(
    name: [*:0]const u8,
    required_extensions: []const [*:0]const u8,
    allocator: std.mem.Allocator,
) !Self {
    var self: Self = undefined;

    self.vulkan_library = switch (builtin.target.os.tag) {
        .linux => std.c.dlopen("libvulkan.so.1", 2),
        .windows => blk: {
            const load_library_fn = @extern(*const fn (name: [*:0]const u8) callconv(.C) ?*anyopaque, .{
                .name = "LoadLibraryA",
                .linkage = .strong,
            });
            break :blk load_library_fn("vulkan-1.dll");
        },
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.target.os.tag)),
    } orelse return error.FailedToLoadVulkan;
    errdefer self.freeLibrary();

    const get_instance_proc_addr = self.loadFunction(
        vk.PfnGetInstanceProcAddr,
        "vkGetInstanceProcAddr",
    );

    self.vkb = try BaseDispatch.load(get_instance_proc_addr);

    const app_info = vk.ApplicationInfo{
        .p_application_name = name,
        .application_version = vk.makeApiVersion(0, 1, 0, 0),
        .p_engine_name = name,
        .engine_version = vk.makeApiVersion(0, 1, 0, 0),
        .api_version = vk.API_VERSION_1_3,
    };

    const supports_validation_layers = blk: {
        var prop_count: u32 = undefined;
        std.debug.assert(try self.vkb.enumerateInstanceLayerProperties(
            &prop_count,
            null,
        ) == .success);

        const props = try allocator.alloc(vk.LayerProperties, @intCast(prop_count));
        defer allocator.free(props);
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

    self.instance = try self.vkb.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = @intCast(required_extensions.len),
        .pp_enabled_extension_names = required_extensions.ptr,
        .enabled_layer_count = if (supports_validation_layers) validation_layers.len else 0,
        .pp_enabled_layer_names = if (supports_validation_layers) &validation_layers else undefined,
    }, null);

    self.vki = try InstanceDispatch.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr);
    errdefer self.vki.destroyInstance(self.instance, null);

    return self;
}

pub fn deinit(self: *Self) void {
    self.vki.destroyInstance(self.instance, null);
    self.freeLibrary();
}

fn freeLibrary(self: *const Self) void {
    switch (builtin.os.tag) {
        .linux => _ = std.c.dlclose(self.vulkan_library),
        .windows => {
            const free_library_fn = @extern(*const fn (hmodule: *anyopaque) callconv(.C) c_int, .{
                .name = "FreeLibrary",
            });
            _ = free_library_fn(self.vulkan_library);
        },
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.target.os.tag)),
    }
}

fn loadFunction(
    self: *const Self,
    comptime FnType: type,
    name: [*:0]const u8,
) FnType {
    return @alignCast(@ptrCast(switch (builtin.target.os.tag) {
        .linux => std.c.dlsym(self.vulkan_library, name),
        .windows => blk: {
            const get_proc_address_fn = @extern(
                *const fn (hmodule: *anyopaque, name: [*:0]const u8) callconv(.C) ?*anyopaque,
                .{
                    .name = "GetProcAddress",
                },
            );
            break :blk get_proc_address_fn(self.vulkan_library, name);
        },
        else => @compileError("Unsupported OS: " ++ @tagName(builtin.target.os.tag)),
    } orelse unreachable));
}
