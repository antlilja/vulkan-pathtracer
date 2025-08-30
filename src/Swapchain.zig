const std = @import("std");
const vk = @import("vulkan");

const GraphicsContext = @import("GraphicsContext.zig");

pub const PresentState = enum {
    optimal,
    suboptimal,
};

pub const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,
    frame_fence: vk.Fence,

    fn init(context: *const GraphicsContext, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try context.device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer context.device.destroyImageView(view, null);

        const image_acquired = try context.device.createSemaphore(&.{}, null);
        errdefer context.device.destroySemaphore(image_acquired, null);

        const render_finished = try context.device.createSemaphore(&.{}, null);
        errdefer context.device.destroySemaphore(render_finished, null);

        const frame_fence = try context.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        errdefer context.device.destroyFence(frame_fence, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
            .frame_fence = frame_fence,
        };
    }

    fn deinit(self: SwapImage, context: *const GraphicsContext) void {
        self.waitForFence(context) catch return;
        context.device.destroyImageView(self.view, null);
        context.device.destroySemaphore(self.image_acquired, null);
        context.device.destroySemaphore(self.render_finished, null);
        context.device.destroyFence(self.frame_fence, null);
    }

    pub fn waitForFence(self: SwapImage, context: *const GraphicsContext) !void {
        _ = try context.device.waitForFences(1, @ptrCast(&self.frame_fence), .true, std.math.maxInt(u64));
    }
};

const Self = @This();

surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
extent: vk.Extent2D,
handle: vk.SwapchainKHR,

swap_images: []SwapImage,
image_index: u32,
next_image_acquired: vk.Semaphore,

pub fn init(
    context: *const GraphicsContext,
    allocator: std.mem.Allocator,
    extent: vk.Extent2D,
) !Self {
    return try initRecycle(
        context,
        allocator,
        extent,
        .null_handle,
    );
}

pub fn initRecycle(
    context: *const GraphicsContext,
    allocator: std.mem.Allocator,
    extent: vk.Extent2D,
    old_handle: vk.SwapchainKHR,
) !Self {
    const caps = try context.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        context.physical_device,
        context.surface,
    );

    const actual_extent = if (caps.current_extent.width != 0xFFFF_FFFF) caps.current_extent else vk.Extent2D{
        .width = std.math.clamp(
            extent.width,
            caps.min_image_extent.width,
            caps.max_image_extent.width,
        ),
        .height = std.math.clamp(
            extent.height,
            caps.min_image_extent.height,
            caps.max_image_extent.height,
        ),
    };
    if (actual_extent.width == 0 or actual_extent.height == 0) return error.InvalidSurfaceDimensions;

    const surface_format = blk: {
        const preferred = vk.SurfaceFormatKHR{
            .format = .b8g8r8a8_unorm,
            .color_space = .srgb_nonlinear_khr,
        };

        var count: u32 = undefined;
        _ = try context.instance.getPhysicalDeviceSurfaceFormatsKHR(
            context.physical_device,
            context.surface,
            &count,
            null,
        );
        const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
        defer allocator.free(surface_formats);
        _ = try context.instance.getPhysicalDeviceSurfaceFormatsKHR(
            context.physical_device,
            context.surface,
            &count,
            surface_formats.ptr,
        );

        for (surface_formats) |sfmt| {
            if (std.meta.eql(sfmt, preferred)) break :blk preferred;
        }

        break :blk surface_formats[0];
    };

    const present_mode = blk: {
        var count: u32 = undefined;
        _ = try context.instance.getPhysicalDeviceSurfacePresentModesKHR(
            context.physical_device,
            context.surface,
            &count,
            null,
        );
        const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
        defer allocator.free(present_modes);
        _ = try context.instance.getPhysicalDeviceSurfacePresentModesKHR(
            context.physical_device,
            context.surface,
            &count,
            present_modes.ptr,
        );

        const preferred = [_]vk.PresentModeKHR{
            .mailbox_khr,
            .immediate_khr,
        };

        for (preferred) |mode| {
            if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
                break :blk mode;
            }
        }

        break :blk .fifo_khr;
    };

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);

    const qfi, const sharing_mode = if (context.graphics_queue.family != context.present_queue.family)
        .{ &.{ context.graphics_queue.family, context.present_queue.family }, vk.SharingMode.concurrent }
    else
        .{ &.{context.graphics_queue.family}, vk.SharingMode.exclusive };

    const handle = try context.device.createSwapchainKHR(&.{
        .surface = context.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = actual_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .queue_family_index_count = @intCast(qfi.len),
        .p_queue_family_indices = qfi.ptr,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old_handle,
    }, null);
    errdefer context.device.destroySwapchainKHR(handle, null);
    if (old_handle != .null_handle) context.device.destroySwapchainKHR(old_handle, null);

    const swap_images = blk: {
        var count: u32 = undefined;
        _ = try context.device.getSwapchainImagesKHR(
            handle,
            &count,
            null,
        );
        const images = try allocator.alloc(vk.Image, count);
        defer allocator.free(images);
        _ = try context.device.getSwapchainImagesKHR(
            handle,
            &count,
            images.ptr,
        );

        const swap_images = try allocator.alloc(SwapImage, count);
        errdefer allocator.free(swap_images);

        var i: usize = 0;
        errdefer for (swap_images[0..i]) |si| si.deinit(context);

        for (images) |image| {
            swap_images[i] = try SwapImage.init(context, image, surface_format.format);
            i += 1;
        }

        break :blk swap_images;
    };
    errdefer {
        for (swap_images) |si| si.deinit(context);
        allocator.free(swap_images);
    }

    var next_image_acquired = try context.device.createSemaphore(&.{}, null);
    errdefer context.device.destroySemaphore(next_image_acquired, null);

    const result = try context.device.acquireNextImageKHR(
        handle,
        std.math.maxInt(u64),
        next_image_acquired,
        .null_handle,
    );
    if (result.result != .success) return error.ImageAcquireFailed;

    std.mem.swap(vk.Semaphore, &swap_images[result.image_index].image_acquired, &next_image_acquired);
    return .{
        .surface_format = surface_format,
        .present_mode = present_mode,
        .extent = actual_extent,
        .handle = handle,
        .swap_images = swap_images,
        .image_index = result.image_index,
        .next_image_acquired = next_image_acquired,
    };
}

fn deinitExceptSwapchain(self: Self, context: *const GraphicsContext, allocator: std.mem.Allocator) void {
    for (self.swap_images) |si| si.deinit(context);
    allocator.free(self.swap_images);
    context.device.destroySemaphore(self.next_image_acquired, null);
}

pub fn waitForAllFences(self: Self, context: *const GraphicsContext) !void {
    for (self.swap_images) |si| si.waitForFence(context) catch {};
}

pub fn deinit(self: Self, context: *const GraphicsContext, allocator: std.mem.Allocator) void {
    self.deinitExceptSwapchain(context, allocator);
    context.device.destroySwapchainKHR(self.handle, null);
}

pub fn recreate(
    self: *Self,
    context: *const GraphicsContext,
    allocator: std.mem.Allocator,
    new_extent: vk.Extent2D,
) !void {
    const old_handle = self.handle;
    self.deinitExceptSwapchain(context, allocator);
    self.* = try initRecycle(
        context,
        allocator,
        new_extent,
        old_handle,
    );
}

pub fn currentImage(self: Self) *const SwapImage {
    return &self.swap_images[self.image_index];
}

pub fn present(
    self: *Self,
    context: *const GraphicsContext,
    cmdbuf: vk.CommandBuffer,
) !PresentState {
    const current = self.currentImage();
    try current.waitForFence(context);
    try context.device.resetFences(1, @ptrCast(&current.frame_fence));

    const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
    try context.device.queueSubmit(
        context.graphics_queue.handle,
        1,
        &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&current.image_acquired),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&current.render_finished),
        }},
        current.frame_fence,
    );

    _ = try context.device.queuePresentKHR(context.present_queue.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @as([*]const vk.Semaphore, @ptrCast(&current.render_finished)),
        .swapchain_count = 1,
        .p_swapchains = @as([*]const vk.SwapchainKHR, @ptrCast(&self.handle)),
        .p_image_indices = @as([*]const u32, @ptrCast(&self.image_index)),
    });

    const result = try context.device.acquireNextImageKHR(
        self.handle,
        std.math.maxInt(u64),
        self.next_image_acquired,
        .null_handle,
    );

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
    self.image_index = result.image_index;

    return switch (result.result) {
        .success => .optimal,
        .suboptimal_khr => .suboptimal,
        else => unreachable,
    };
}
