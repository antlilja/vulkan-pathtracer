const std = @import("std");
const vk = @import("vulkan");
const clap = @import("clap");

const zw = @import("zig-window");

const Timer = @import("Timer.zig");
const Input = @import("Input.zig");
const Nuklear = @import("Nuklear.zig");

const Vec3 = @import("Vec3.zig");

const Instance = @import("Instance.zig");
const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const Image = @import("Image.zig");

const NuklearPass = @import("NuklearPass.zig");
const RaytracingPass = @import("RaytracingPass.zig");

const Camera = @import("Camera.zig");

const app_name = "Engine";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                 Display this help and exit.
        \\-s, --scene-path <str>     Path to GLTF scene that is to be rendered.
        \\-n, --num-samples <u32>    How many samples per frame will be computed.
        \\-b, --num-bounces <u32>    How many times can a ray bounce before being terminated.
        \\-x, --resolution-x <u32>   Horizontal resolution (default is 1920) 
        \\-y, --resolution-y <u32>   Vertical resolution (default is 1080) 
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

    var extent = vk.Extent2D{
        .width = res.args.@"resolution-x" orelse 1920,
        .height = res.args.@"resolution-y" orelse 1080,
    };

    try zw.init(allocator);
    defer zw.deinit();

    var input: Input = .{};

    const window = try zw.createWindow(.{
        .name = app_name,
        .width = extent.width,
        .height = extent.height,
        .resizable = false,
        .event_handler = .{
            .handle = @ptrCast(&input),
            .handle_event_fn = @ptrCast(&Input.handleEvent),
        },
    });
    defer window.destroy();

    var instance = try Instance.init(
        app_name,
        zw.requiredVulkanInstanceExtensions(),
        allocator,
    );
    defer instance.deinit();

    const surface = try window.createVulkanSurface(
        vk.Instance,
        vk.SurfaceKHR,
        instance.instance,
        @ptrCast(instance.vkb.dispatch.vkGetInstanceProcAddr),
        null,
    );
    defer instance.vki.destroySurfaceKHR(
        instance.instance,
        surface,
        null,
    );

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

    var nuklear = try Nuklear.init(allocator);
    defer nuklear.deinit(allocator);

    var nuklear_pass = try NuklearPass.init(
        &device,
        swapchain.surface_format.format,
        pool,
        1024 * 512,
        1024 * 128,
        &nuklear,
        allocator,
    );
    defer nuklear_pass.deinit(&device, allocator);

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

    var cmdbufs = try allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    try device.vkd.allocateCommandBuffers(device.device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @as(u32, @truncate(cmdbufs.len)),
    }, cmdbufs.ptr);
    defer {
        device.vkd.freeCommandBuffers(device.device, pool, @truncate(cmdbufs.len), cmdbufs.ptr);
        allocator.free(cmdbufs);
    }

    var camera = Camera.new(
        Vec3.new(0.0, 0.0, 0.0),
        0.0,
        0.0,
        std.math.pi * 0.25,
    );
    camera.update(@as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)));

    var camera_update: bool = false;

    var timer = Timer.start();
    while (window.isOpen()) {
        defer timer.lap();
        defer nuklear.clear();

        zw.pollEvents();

        input.update();
        nuklear.update(&input);

        const delta_time = timer.delta_time;

        const width, const height = window.getSize();

        // Don't present or resize swapchain while the window is minimized
        if (width == 0 or height == 0) continue;

        // Camera movement
        if (!nuklear.isCapturingInput()) {
            var velocity_camera_space = Vec3.zero;
            var velocity = Vec3.zero;
            if (input.isKeyPressed(.w)) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(0.0, 0.0, delta_time));
            }

            if (input.isKeyPressed(.s)) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(0.0, 0.0, -delta_time));
            }

            if (input.isKeyPressed(.a)) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(delta_time, 0.0, 0.0));
            }

            if (input.isKeyPressed(.d)) {
                velocity_camera_space = velocity_camera_space.add(Vec3.new(-delta_time, 0.0, 0.0));
            }

            if (input.isKeyPressed(.space)) {
                velocity = velocity.add(Vec3.new(0.0, delta_time, 0.0));
            }

            if (input.isKeyPressed(.left_ctrl)) {
                velocity = velocity.add(Vec3.new(0.0, -delta_time, 0.0));
            }

            const speed: f32 = if (input.isKeyPressed(.left_shift)) 20.0 else 10.0;

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

            if (input.isMouseButtonPressed(.left)) {
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

        if (nuklear.begin(
            "FPS Info",
            .{
                .x = 0.0,
                .y = 0.0,
                .w = 175.0,
                .h = 75.0,
            },
            .{ .no_scrollbar = true },
        )) {
            nuklear.layout_row_static(30.0, 175, 1);

            nuklear.labelFmt(
                "FPS: {d:.0}",
                .{1.0 / timer.frame_time},
                .left,
            );
            nuklear.labelFmt(
                "Frame time: {d:.4} ms",
                .{timer.frame_time * std.time.ms_per_s},
                .left,
            );
        }
        nuklear.end();

        const cmdbuf = cmdbufs[swapchain.image_index];
        try swapchain.currentSwapImage().waitForFence(&device);

        {
            const swap_image = swapchain.currentSwapImage().image;
            const swap_image_view = swapchain.currentSwapImage().view;

            try device.vkd.beginCommandBuffer(cmdbuf, &.{});

            Image.imageSetLayout(
                &device,
                cmdbuf,
                swap_image,
                .undefined,
                .transfer_dst_optimal,
            );

            try raytracing_pass.record(
                &device,
                swap_image,
                extent,
                cmdbuf,
                camera,
                timer.frame_count,
            );

            Image.imageSetLayout(
                &device,
                cmdbuf,
                swap_image,
                .transfer_dst_optimal,
                .present_src_khr,
            );

            try nuklear_pass.record(
                &device,
                cmdbuf,
                swap_image_view,
                extent,
                &nuklear,
            );

            try device.vkd.endCommandBuffer(cmdbuf);
        }

        const state = swapchain.present(&device, cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent.width != width or extent.height != height) {
            try device.vkd.deviceWaitIdle(device.device);

            const prev_num_swap_images = swapchain.swap_images.len;

            extent.width = width;
            extent.height = height;
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

            if (prev_num_swap_images != swapchain.swap_images.len) {
                device.vkd.freeCommandBuffers(
                    device.device,
                    pool,
                    @intCast(cmdbufs.len),
                    cmdbufs.ptr,
                );
                allocator.free(cmdbufs);

                cmdbufs = try allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
                try device.vkd.allocateCommandBuffers(device.device, &.{
                    .command_pool = pool,
                    .level = .primary,
                    .command_buffer_count = @intCast(cmdbufs.len),
                }, cmdbufs.ptr);
            }
        }
    }

    try swapchain.waitForAllFences(&device);
}
