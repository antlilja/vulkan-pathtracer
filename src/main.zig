const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const za = @import("zalgebra");
const clap = @import("clap");

const zw = @import("zig-window");

const Timer = @import("Timer.zig");
const Input = @import("Input.zig");
const Nuklear = @import("Nuklear.zig");

const Features = @import("Features.zig");
const GraphicsContext = @import("GraphicsContext.zig");
const Swapchain = @import("Swapchain.zig");
const Image = @import("Image.zig");

const NuklearPass = @import("NuklearPass.zig");
const RaytracingPass = @import("RaytracingPass.zig");

const Camera = @import("Camera.zig");

const Stats = @import("Stats.zig");

const app_name = "Engine";

pub const vk_extra_apis = NuklearPass.apis ++ RaytracingPass.apis;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                            Display this help and exit.
        \\-s, --scene-path <str>                Path to GLTF scene that is to be rendered.
        \\-n, --num-samples <u32>               How many samples per frame will be computed.
        \\-b, --num-bounces <u32>               How many times can a ray bounce before being terminated.
        \\-x, --resolution-x <u32>              Horizontal resolution (default is 1920)
        \\-y, --resolution-y <u32>              Vertical resolution (default is 1080)
        \\-d, --render-resolution-divider <u32> Resolution divider (default is 1)
        \\-v, --enable-validation               Enable vulkan validation layers
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

    const render_resolution_divider = res.args.@"render-resolution-divider" orelse 1;

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

    var gc = blk: {
        const features = try Features.init(
            NuklearPass.features ++ RaytracingPass.features,
            allocator,
        );
        defer features.deinit();
        break :blk try GraphicsContext.init(
            allocator,
            "vulkan-pathtracer",
            window,
            vk.API_VERSION_1_3,
            zw.requiredVulkanInstanceExtensions(),
            &(NuklearPass.extensions ++
                RaytracingPass.extensions ++
                [_][*:0]const u8{vk.extensions.ext_memory_budget.name}),
            features.base,
            (res.args.@"enable-validation" != 0) or (builtin.mode == .Debug),
        );
    };
    defer gc.deinit();

    var swapchain = try Swapchain.init(
        &gc,
        allocator,
        extent,
    );
    defer swapchain.deinit(&gc, allocator);

    const render_pass = blk: {
        const color_attachment = vk.AttachmentDescription{
            .format = swapchain.surface_format.format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .load,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .present_src_khr,
            .final_layout = .present_src_khr,
        };

        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };

        const subpass = vk.SubpassDescription{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
        };

        break :blk try gc.device.createRenderPass(&.{
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
        }, null);
    };
    defer gc.device.destroyRenderPass(render_pass, null);

    var framebuffers = try createFramebuffers(
        &gc,
        allocator,
        render_pass,
        &swapchain,
    );
    defer destroyFramebuffers(&gc, allocator, framebuffers);

    const pool = try gc.device.createCommandPool(&.{
        .queue_family_index = gc.graphics_queue.family,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null);
    defer gc.device.destroyCommandPool(pool, null);

    var nuklear = try Nuklear.init(allocator);
    defer nuklear.deinit(allocator);

    var nuklear_pass = try NuklearPass.init(
        &gc,
        pool,
        render_pass,
        1024 * 512,
        1024 * 128,
        &nuklear,
        allocator,
    );
    defer nuklear_pass.deinit(&gc, allocator);

    var raytracing_pass = try RaytracingPass.init(
        &gc,
        swapchain.extent,
        swapchain.surface_format.format,
        pool,
        allocator,
        scene_path,
        num_samples,
        num_bounces,
        render_resolution_divider,
    );
    defer raytracing_pass.deinit(&gc);

    var cmdbufs = try allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    try gc.device.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @as(u32, @truncate(cmdbufs.len)),
    }, cmdbufs.ptr);
    defer {
        gc.device.freeCommandBuffers(pool, @truncate(cmdbufs.len), cmdbufs.ptr);
        allocator.free(cmdbufs);
    }

    var camera = Camera.new(
        std.math.pi * 0.25,
        @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)),
        za.Vec3.new(0.0, 0.0, 0.0),
    );

    var stats = try Stats.init(&gc, allocator);
    defer stats.deinit(allocator);

    var total_frame_count: u32 = 0;

    var timer = Timer.start();
    while (window.isOpen()) {
        defer {
            timer.lap();
            stats.lap(timer);

            input.reset();
            zw.pollEvents();
        }

        // Camera movement
        if (!nuklear.isCapturingInput()) camera.update(input, timer);

        const width, const height = window.getSize();

        // Don't present or resize swapchain while the window is minimized
        if (width == 0 or height == 0) continue;
        defer {
            total_frame_count += 1;
            nuklear.reset(input);
        }

        stats.window(&nuklear);

        const cmdbuf = cmdbufs[swapchain.image_index];
        {
            const swap_image = swapchain.currentImage();
            try swap_image.waitForFence(&gc);

            try gc.device.resetCommandBuffer(cmdbuf, .{});
            try gc.device.beginCommandBuffer(cmdbuf, &.{});

            try raytracing_pass.record(
                &gc,
                swap_image.image,
                extent,
                cmdbuf,
                camera,
                total_frame_count,
            );

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

            gc.device.cmdSetViewport(
                cmdbuf,
                0,
                1,
                @ptrCast(&viewport),
            );
            gc.device.cmdSetScissor(
                cmdbuf,
                0,
                1,
                @ptrCast(&scissor),
            );

            const render_area = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = extent,
            };

            gc.device.cmdBeginRenderPass(cmdbuf, &.{
                .render_pass = render_pass,
                .framebuffer = framebuffers[swapchain.image_index],
                .render_area = render_area,
                .clear_value_count = 0,
                .p_clear_values = undefined,
            }, .@"inline");

            try nuklear_pass.record(
                &gc,
                cmdbuf,
                extent,
                &nuklear,
            );
            gc.device.cmdEndRenderPass(cmdbuf);
            try gc.device.endCommandBuffer(cmdbuf);
        }

        const state = swapchain.present(&gc, cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal or extent.width != width or extent.height != height) {
            const prev_num_swap_images = swapchain.swap_images.len;

            extent.width = width;
            extent.height = height;
            try swapchain.recreate(
                &gc,
                allocator,
                extent,
            );

            destroyFramebuffers(&gc, allocator, framebuffers);
            framebuffers = try createFramebuffers(
                &gc,
                allocator,
                render_pass,
                &swapchain,
            );

            camera.updateAspectRatio(
                @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height)),
            );

            try raytracing_pass.resize(
                &gc,
                swapchain.extent,
                swapchain.surface_format.format,
                pool,
            );

            if (prev_num_swap_images != swapchain.swap_images.len) {
                gc.device.freeCommandBuffers(
                    pool,
                    @intCast(cmdbufs.len),
                    cmdbufs.ptr,
                );
                allocator.free(cmdbufs);

                cmdbufs = try allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
                try gc.device.allocateCommandBuffers(&.{
                    .command_pool = pool,
                    .level = .primary,
                    .command_buffer_count = @intCast(cmdbufs.len),
                }, cmdbufs.ptr);
            }
        }
    }

    try swapchain.waitForAllFences(&gc);
}

fn createFramebuffers(
    gc: *const GraphicsContext,
    allocator: std.mem.Allocator,
    render_pass: vk.RenderPass,
    swapchain: *const Swapchain,
) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| gc.device.destroyFramebuffer(
        fb,
        null,
    );

    for (framebuffers) |*fb| {
        fb.* = try gc.device.createFramebuffer(&.{
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(
    gc: *const GraphicsContext,
    allocator: std.mem.Allocator,
    framebuffers: []const vk.Framebuffer,
) void {
    for (framebuffers) |fb| gc.device.destroyFramebuffer(fb, null);
    allocator.free(framebuffers);
}
