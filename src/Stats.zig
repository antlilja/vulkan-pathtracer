const std = @import("std");
const vk = @import("vulkan");

const Timer = @import("Timer.zig");
const GraphicsContext = @import("GraphicsContext.zig");
const Nuklear = @import("Nuklear.zig");

const Self = @This();

frame_count_accumulator: u32 = 0,
frame_time_accumulator: f32 = 0.0,

frame_count: u32 = 0,
average_frame_time: f32 = 1.0,

average_frame_time_buffer: []f32,
average_frame_time_buffer_len: u32 = 0,

budgets: []const vk.DeviceSize,
usages: []const vk.DeviceSize,
flags: []const vk.MemoryPropertyFlags,

pub fn init(gc: *const GraphicsContext, allocator: std.mem.Allocator) !Self {
    const average_frame_time_buffer = try allocator.alloc(f32, 100);
    errdefer allocator.free(average_frame_time_buffer);

    var budget_props = vk.PhysicalDeviceMemoryBudgetPropertiesEXT{
        .heap_budget = [_]vk.DeviceSize{0} ** vk.MAX_MEMORY_HEAPS,
        .heap_usage = [_]vk.DeviceSize{0} ** vk.MAX_MEMORY_HEAPS,
    };
    var props = vk.PhysicalDeviceMemoryProperties2{
        .p_next = @ptrCast(&budget_props),
        .memory_properties = undefined,
    };
    gc.instance.getPhysicalDeviceMemoryProperties2(gc.physical_device, &props);

    const budgets = try allocator.dupe(
        vk.DeviceSize,
        budget_props.heap_budget[0..props.memory_properties.memory_heap_count],
    );
    errdefer allocator.free(budgets);

    const usages = try allocator.dupe(
        vk.DeviceSize,
        budget_props.heap_usage[0..props.memory_properties.memory_heap_count],
    );
    errdefer allocator.free(usages);

    const flags = try allocator.alloc(vk.MemoryPropertyFlags, props.memory_properties.memory_heap_count);
    errdefer allocator.free(flags);
    @memset(flags, .{});
    for (props.memory_properties.memory_types[0..props.memory_properties.memory_type_count]) |@"type"| {
        inline for (std.meta.fields(vk.MemoryPropertyFlags)) |field| {
            @field(flags[@"type".heap_index], field.name) =
                @field(flags[@"type".heap_index], field.name) or
                @field(@"type".property_flags, field.name);
        }
    }

    return .{
        .budgets = budgets,
        .usages = usages,
        .flags = flags,
        .average_frame_time_buffer = average_frame_time_buffer,
    };
}

pub fn lap(self: *Self, timer: Timer) void {
    self.frame_count_accumulator += 1;
    self.frame_time_accumulator += timer.delta_time;

    if (!timer.second_elapsed) return;

    self.frame_count = self.frame_count_accumulator;
    self.frame_count_accumulator = 0;

    self.average_frame_time = self.frame_time_accumulator / @as(f32, @floatFromInt(self.frame_count));
    self.frame_time_accumulator = 0.0;

    if (self.average_frame_time_buffer_len == self.average_frame_time_buffer.len) std.mem.copyForwards(
        f32,
        self.average_frame_time_buffer[0..(self.average_frame_time_buffer.len - 1)],
        self.average_frame_time_buffer[1..],
    ) else self.average_frame_time_buffer_len += 1;

    self.average_frame_time_buffer[self.average_frame_time_buffer_len - 1] = self.average_frame_time;
}

pub fn getAverageFrameTimeBuffer(self: Self) []const f32 {
    return self.average_frame_time_buffer[0..self.average_frame_time_buffer_len];
}

pub fn window(self: Self, nuklear: *Nuklear) void {
    defer nuklear.end();
    if (nuklear.begin(
        "Statistics",
        .{
            .x = 0.0,
            .y = 0.0,
            .w = 200.0,
            .h = 100.0,
        },
        .{
            .border = true,
            .minimizable = true,
            .moveable = true,
            .scalable = true,
        },
    )) {
        if (nuklear.treePush(
            .tab,
            "Performance",
            .minimized,
            @src(),
        )) {
            defer nuklear.treePop();

            nuklear.labelFmt(
                "FPS: {}",
                .{self.frame_count},
                .left,
            );
            nuklear.labelFmt(
                "Frame time: {d:.4} ms",
                .{self.average_frame_time * std.time.ms_per_s},
                .left,
            );

            nuklear.layoutRowStatic(100.0, 200.0, 1);
            nuklear.plot(
                .lines,
                self.getAverageFrameTimeBuffer(),
                0,
            );
        }

        if (nuklear.treePush(
            .tab,
            "Memory",
            .minimized,
            @src(),
        )) {
            defer nuklear.treePop();
            for (
                self.budgets,
                self.usages,
                self.flags,
                0..,
            ) |
                budget,
                usage,
                flags,
                i,
            | {
                if (nuklear.treePushIdFmt(
                    .tab,
                    "Heap: {}",
                    .{i},
                    .minimized,
                    @src(),
                    @intCast(i),
                )) {
                    defer nuklear.treePop();
                    nuklear.labelFmt("Usage: {} MB", .{usage / 1000000}, .left);
                    nuklear.labelFmt("Budget: {} MB", .{budget / 1000000}, .left);

                    inline for (std.meta.fields(vk.MemoryPropertyFlags)) |field| {
                        if (@field(flags, field.name)) {
                            nuklear.label(field.name, .left);
                        }
                    }
                }
            }
        }
    }
}

pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
    allocator.free(self.flags);
    allocator.free(self.usages);
    allocator.free(self.budgets);
    allocator.free(self.average_frame_time_buffer);
}
