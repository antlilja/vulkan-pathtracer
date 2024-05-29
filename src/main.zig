const std = @import("std");
const vk = @import("vulkan");
const clap = @import("clap");
const glfw = @import("glfw.zig");

const Timer = @import("Timer.zig");
const Input = @import("Input.zig");

const Vec3 = @import("Vec3.zig");

const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const Image = @import("Image.zig");

const RaytracingPass = @import("RaytracingPass.zig");

const Camera = @import("Camera.zig");

const app_name = "Engine";

pub fn main() !void {
    if (glfw.glfwInit() != glfw.GLFW_TRUE) return error.FailedToInitGLWF;
    defer glfw.glfwTerminate();

    if (glfw.glfwVulkanSupported() != glfw.GLFW_TRUE) {
        try std.io.getStdErr().writer().print("GLFW could not find vulkan", .{});
        std.process.exit(1);
    }

    var extent = vk.Extent2D{ .width = 960, .height = 540 };

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    const window = glfw.glfwCreateWindow(
        @intCast(extent.width),
        @intCast(extent.height),
        app_name,
        null,
        null,
    ) orelse return error.FailedToInitWindow;
    defer glfw.glfwDestroyWindow(window);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-s, --scene-path <str>     Path to GLTF scene that is to be rendered.
        \\-n, --num-samples <u32>    How many samples per frame will be computed.
        \\-b, --num-bounces <u32>    How many times can a ray bounce before being terminated.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| switch (err) {
        error.InvalidArgument => {
            diag.report(std.io.getStdErr().writer(), err) catch {};
            return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
        },
        else => {
            diag.report(std.io.getStdErr().writer(), err) catch {};
            return err;
        },
    };
    defer res.deinit();

    if (res.args.help != 0) return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    const scene_path = res.args.@"scene-path" orelse {
        try std.io.getStdErr().writer().print("Missing path to scene from arguments\n", .{});

        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    };

    const num_samples = res.args.@"num-samples" orelse 1;
    const num_bounces = res.args.@"num-bounces" orelse 2;

    var instance = try Instance.init(app_name);
    defer instance.deinit();

    const surface = blk: {
        var surface: vk.SurfaceKHR = undefined;
        if (glfw.glfwCreateWindowSurface(
            instance.instance,
            window,
            null,
            &surface,
        ) != .success) {
            return error.FailedToInitSurface;
        }
        break :blk surface;
    };
    defer instance.vki.destroySurfaceKHR(instance.instance, surface, null);

    const device = try Device.init(&instance, surface, allocator);
    defer device.deinit();

    var swapchain = try Swapchain.init(
        &instance,
        &device,
        surface,
        allocator,
        extent,
    );
    defer swapchain.deinit(&device, allocator);

    const pool = try device.vkd.createCommandPool(device.device, &.{
        .queue_family_index = device.graphics_queue.family,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
    defer device.vkd.destroyCommandPool(device.device, pool, null);


    var raytracing_pass = try RaytracingPass.init(
        &instance,
        &device,
        swapchain.extent,
        swapchain.surface_format.format,
        pool,
        allocator,
        scene_path,
        num_samples,
        num_bounces,
    );
    defer raytracing_pass.deinit(&device, allocator);

    var cmdbufs = try createCommandBuffers(
        &device,
        pool,
        &swapchain,
        allocator,
    );
    defer destroyCommandBuffers(&device, pool, allocator, cmdbufs);

    var camera = Camera.new(
        Vec3.new(0.0, 0.0, 0.0),
        0.0,
        0.0,
        std.math.pi * 0.25,
    );
    camera.update(@as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)));

    var camera_update: bool = false;

    var input = Input.init(window);
    var timer = Timer.start();
    while (glfw.glfwWindowShouldClose(window) == glfw.GLFW_FALSE) {
        defer timer.lap();

        var w: c_int = undefined;
        var h: c_int = undefined;
        glfw.glfwGetFramebufferSize(window, &w, &h);
        glfw.glfwPollEvents();

        // Don't present or resize swapchain while the window is minimized
        if (w == 0 or h == 0) {
            continue;
        }
        const cmdbuf = cmdbufs[swapchain.image_index];
        input.update();


        const delta_time = timer.delta_time;


        // Camera movement
        {
            var velocity_camera_space = Vec3.zero;
            var velocity = Vec3.zero;
            if (glfw.glfwGetKey(window, glfw.GLFW_KEY_W) == glfw.GLFW_PRESS) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(0.0, 0.0, delta_time));
            }

            if (glfw.glfwGetKey(window, glfw.GLFW_KEY_S) == glfw.GLFW_PRESS) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(0.0, 0.0, -delta_time));
            }

            if (glfw.glfwGetKey(window, glfw.GLFW_KEY_A) == glfw.GLFW_PRESS) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(delta_time, 0.0, 0.0));
            }

            if (glfw.glfwGetKey(window, glfw.GLFW_KEY_D) == glfw.GLFW_PRESS) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(-delta_time, 0.0, 0.0));
            }

            if (glfw.glfwGetKey(window, glfw.GLFW_KEY_SPACE) == glfw.GLFW_PRESS) {
                velocity = velocity.add(Vec3.new(0.0, delta_time, 0.0));
            }

            if (glfw.glfwGetKey(window, glfw.GLFW_KEY_LEFT_CONTROL) == glfw.GLFW_PRESS) {
                velocity = velocity.add(Vec3.new(0.0, -delta_time, 0.0));
            }

            const speed: f32 = if (glfw.glfwGetKey(window, glfw.GLFW_KEY_LEFT_SHIFT) == glfw.GLFW_PRESS) 20.0 else 10.0;

            velocity_camera_space = velocity_camera_space.scale(speed);
            velocity = velocity.scale(speed);

            camera_update = false;
            if (!velocity_camera_space.eql(Vec3.zero)) {
                camera.moveRotated(velocity_camera_space);
                camera_update = true;
            }

            if (!velocity.eql(Vec3.zero)) {
                camera.move(velocity);
                camera_update = true;
            }

            if (glfw.glfwGetMouseButton(window, glfw.GLFW_MOUSE_BUTTON_LEFT) == glfw.GLFW_PRESS) {
                camera.yaw -= @as(f32, @floatCast(input.cursor_delta_x)) * 0.005;
                camera.pitch += @as(f32, @floatCast(input.cursor_delta_y)) * 0.005;

                if (input.cursor_delta_x != 0.0 or input.cursor_delta_y != 0.0) {
                    camera_update = true;
                }
            }

            if (camera_update) {
                camera.update(@as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)));
            }
        }




        try swapchain.currentSwapImage().waitForFence(&device);
        try recordCommandBuffer(
            &device,
            cmdbuf,
            &raytracing_pass,
            swapchain.currentSwapImage().image,
            swapchain.extent,
            camera,
            timer.frame_count,
        );

        const state = swapchain.present(&device, cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent.width != @as(u32, @intCast(w)) or extent.height != @as(u32, @intCast(h))) {
            try device.vkd.deviceWaitIdle(device.device);

            extent.width = @intCast(w);
            extent.height = @intCast(h);
            try swapchain.recreate(
                &instance,
                &device,
                surface,
                allocator,
                extent,
            );

            camera.update(@as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)));

            try raytracing_pass.resize(
                &device,
                swapchain.extent,
                swapchain.surface_format.format,
                pool,
            );

            destroyCommandBuffers(&device, pool, allocator, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &device,
                pool,
                &swapchain,
                allocator,
            );
        }
    }

    try swapchain.waitForAllFences(&device);
}

fn recordCommandBuffer(
    device: *const Device,
    cmdbuf: vk.CommandBuffer,
    ray_tracing_pass: *const RaytracingPass,
    swap_image: vk.Image,
    extent: vk.Extent2D,
    camera: Camera,
    frame_count: u32,
) !void {
    try device.vkd.beginCommandBuffer(cmdbuf, &.{});

    Image.imageSetLayout(
        device,
        cmdbuf,
        swap_image,
        .undefined,
        .transfer_dst_optimal,
    );

    try ray_tracing_pass.record(
        device,
        swap_image,
        extent,
        cmdbuf,
        camera,
        frame_count,
    );

    Image.imageSetLayout(
        device,
        cmdbuf,
        swap_image,
        .transfer_dst_optimal,
        .present_src_khr,
    );


    try device.vkd.endCommandBuffer(cmdbuf);
}

fn createCommandBuffers(
    device: *const Device,
    pool: vk.CommandPool,
    swapchain: *const Swapchain,
    allocator: std.mem.Allocator,
) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    errdefer allocator.free(cmdbufs);

    try device.vkd.allocateCommandBuffers(device.device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @as(u32, @truncate(cmdbufs.len)),
    }, cmdbufs.ptr);

    return cmdbufs;
}

fn destroyCommandBuffers(
    device: *const Device,
    pool: vk.CommandPool,
    allocator: std.mem.Allocator,
    cmdbufs: []vk.CommandBuffer,
) void {
    device.vkd.freeCommandBuffers(device.device, pool, @truncate(cmdbufs.len), cmdbufs.ptr);
    allocator.free(cmdbufs);
}
