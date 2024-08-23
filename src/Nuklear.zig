const std = @import("std");

pub const nk = @cImport({
    @cDefine("NK_INCLUDE_FIXED_TYPES", {});
    @cDefine("NK_INCLUDE_VERTEX_BUFFER_OUTPUT", {});
    @cDefine("NK_INCLUDE_DEFAULT_FONT", {});
    @cDefine("NK_INCLUDE_FONT_BAKING", {});
    @cInclude("nuklear.h");
});

const Input = @import("Input.zig");

pub const WindowFlags = packed struct(c_uint) {
    border: bool = false,
    moveable: bool = false,
    scalable: bool = false,
    closable: bool = false,
    minimizable: bool = false,
    no_scrollbar: bool = false,
    title: bool = false,
    background: bool = false,
    scale_left: bool = false,
    no_input: bool = false,
    reserved: u22 = undefined,
};

pub const TextAlignment = enum(c_uint) {
    left = nk.NK_TEXT_LEFT,
    centered = nk.NK_TEXT_CENTERED,
    right = nk.NK_TEXT_RIGHT,
};

pub const TreeType = enum(c_uint) {
    node = nk.NK_TREE_NODE,
    tab = nk.NK_TREE_TAB,
};

pub const CollapseState = enum(c_uint) {
    minimized = nk.NK_MINIMIZED,
    maximized = nk.NK_MAXIMIZED,
};

pub const ChartType = enum(c_uint) {
    lines = nk.NK_CHART_LINES,
    column = nk.NK_CHART_COLUMN,
};

const Self = @This();

font_atlas_memory: []const u8,
font_atlas: nk.nk_font_atlas,

font_atlas_data: []const u8,
font_atlas_width: u32,
font_atlas_height: u32,

context_memory: []const u8,
context: nk.nk_context,

cmd_buffer_memory: []const u8,
cmd_buffer: nk.struct_nk_buffer,

pub fn init(allocator: std.mem.Allocator) !Self {
    const font_atlas, const font_atlas_memory, const font, const font_atlas_data, const font_atlas_width, const font_atlas_height = blk: {
        const font_atlas_memory = try allocator.alloc(u8, 1024 * 1024 * 2);
        errdefer allocator.free(font_atlas_memory);

        const NuklearAllocator = struct {
            buffer: []u8,
            index: usize,
            last_memory: usize,
            last_memory_size: usize,

            fn alloc(user_data: nk.nk_handle, ptr: ?*anyopaque, size: nk.nk_size) callconv(.C) ?*anyopaque {
                _ = ptr;
                var allocator_info: *@This() = @alignCast(@ptrCast(user_data.ptr.?));

                if (allocator_info.index + size >= allocator_info.buffer.len) return null;

                const memory = &allocator_info.buffer[allocator_info.index];
                allocator_info.last_memory = @intFromPtr(memory);

                const prev_index = allocator_info.index;
                allocator_info.index += size;
                allocator_info.index = std.mem.alignForward(u64, allocator_info.index, 16);

                allocator_info.last_memory_size = allocator_info.index - prev_index;

                return @ptrCast(memory);
            }

            fn free(user_data: nk.nk_handle, ptr: ?*anyopaque) callconv(.C) void {
                var allocator_info: *@This() = @alignCast(@ptrCast(user_data.ptr.?));
                allocator_info = allocator_info;

                if (@intFromPtr(ptr) == allocator_info.last_memory) allocator_info.index -= allocator_info.last_memory_size;
            }
        };

        var nk_allocator_user_data: NuklearAllocator = .{
            .buffer = font_atlas_memory,
            .index = @as(usize, 0),
            .last_memory = undefined,
            .last_memory_size = undefined,
        };

        var nk_allocator = nk.struct_nk_allocator{
            .userdata = nk.nk_handle_ptr(@ptrCast(&nk_allocator_user_data)),
            .alloc = &NuklearAllocator.alloc,
            .free = &NuklearAllocator.free,
        };

        var font_atlas: nk.nk_font_atlas = undefined;
        nk.nk_font_atlas_init(&font_atlas, &nk_allocator);

        nk.nk_font_atlas_begin(&font_atlas);
        defer nk.nk_font_atlas_end(&font_atlas, nk.nk_handle_id(1), null);
        const font = nk.nk_font_atlas_add_default(&font_atlas, 13.0, null);

        var atlas_width: c_int = undefined;
        var atlas_height: c_int = undefined;
        const atlas_image: [*]const u8 = @ptrCast(nk.nk_font_atlas_bake(
            &font_atlas,
            &atlas_width,
            &atlas_height,
            nk.NK_FONT_ATLAS_RGBA32,
        ) orelse return error.FailedToBakeFont);

        const font_atlas_data = try allocator.dupe(u8, atlas_image[0..@intCast(atlas_width * atlas_height * 4)]);
        errdefer allocator.free(font_atlas_data);

        break :blk .{
            font_atlas,
            font_atlas_memory,
            font,
            font_atlas_data,
            @as(u32, @intCast(atlas_width)),
            @as(u32, @intCast(atlas_height)),
        };
    };
    errdefer allocator.free(font_atlas_data);
    errdefer allocator.free(font_atlas_memory);

    const context_memory_size = 1024 * 1024;
    const context_memory = try allocator.alloc(u8, context_memory_size);
    errdefer allocator.free(context_memory);

    var context: nk.nk_context = undefined;
    if (nk.nk_init_fixed(
        &context,
        @ptrCast(context_memory.ptr),
        context_memory_size,
        &font.*.handle,
    ) != nk.nk_true) {
        return error.FailedToInitNuklear;
    }
    errdefer nk.nk_free(&context);

    const cmd_buffer_memory_size = 1024 * 1024 * 2;
    const cmd_buffer_memory = try allocator.alloc(u8, cmd_buffer_memory_size);
    errdefer allocator.free(cmd_buffer_memory);
    var cmd_buffer: nk.struct_nk_buffer = undefined;
    nk.nk_buffer_init_fixed(&cmd_buffer, @ptrCast(cmd_buffer_memory.ptr), cmd_buffer_memory_size);

    return .{
        .font_atlas_memory = font_atlas_memory,
        .font_atlas = font_atlas,

        .font_atlas_data = font_atlas_data,
        .font_atlas_width = font_atlas_width,
        .font_atlas_height = font_atlas_height,

        .context_memory = context_memory,
        .context = context,

        .cmd_buffer_memory = cmd_buffer_memory,
        .cmd_buffer = cmd_buffer,
    };
}

pub fn update(self: *Self, input: Input) void {
    nk.nk_input_begin(&self.context);
    defer nk.nk_input_end(&self.context);

    nk.nk_input_motion(
        &self.context,
        input.cursor_x,
        input.cursor_y,
    );

    nk.nk_input_button(
        &self.context,
        nk.NK_BUTTON_LEFT,
        input.cursor_x,
        input.cursor_y,
        if (input.isMouseButtonPressed(.left)) nk.nk_true else nk.nk_false,
    );

    for (0..9) |i| {
        if (input.isKeyJustPressed(@enumFromInt(@intFromEnum(Input.Key.zero) + i))) {
            const byte: u8 = @intCast(i);
            nk.nk_input_char(&self.context, byte + '0');
        }
    }

    for (0..26) |i| {
        if (input.isKeyJustPressed(@enumFromInt(@intFromEnum(Input.Key.a) + i))) {
            const byte: u8 = @intCast(i);
            nk.nk_input_char(&self.context, byte + 'a');
        }
    }

    if (input.isKeyJustPressed(Input.Key.period)) nk.nk_input_char(&self.context, '.');
    if (input.isKeyJustPressed(Input.Key.comma)) nk.nk_input_char(&self.context, ',');

    nk.nk_input_key(
        &self.context,
        nk.NK_KEY_BACKSPACE,
        if (input.isKeyPressed(.backspace)) nk.nk_true else nk.nk_false,
    );
    nk.nk_input_key(
        &self.context,
        nk.NK_KEY_ENTER,
        if (input.isKeyPressed(.enter)) nk.nk_true else nk.nk_false,
    );

    nk.nk_input_scroll(&self.context, .{
        .x = 0.0,
        .y = @floatFromInt(input.scroll),
    });
}

pub fn clear(self: *Self) void {
    nk.nk_buffer_clear(&self.cmd_buffer);
    nk.nk_clear(&self.context);
}

pub fn isCapturingInput(self: *Self) bool {
    return nk.nk_item_is_any_active(&self.context) != 0;
}

pub fn getDrawCommands(
    self: *Self,
    comptime Vertex: type,
    vertex_buffer_memory: []u8,
    index_buffer_memory: []u8,
) struct {
    cmd: ?*const nk.struct_nk_draw_command,

    pub fn next(it: *@This(), context: *Self) ?struct {
        texture_id: u32,
        count: u32,
        clip_rect: struct {
            x: f32,
            y: f32,
            w: f32,
            h: f32,
        },
    } {
        const last_cmd = (it.cmd orelse return null).*;

        it.cmd = nk.nk__draw_next(it.cmd, &context.cmd_buffer, &context.context);

        return .{
            .texture_id = @intCast(last_cmd.texture.id),
            .count = @intCast(last_cmd.elem_count),
            .clip_rect = .{
                .x = last_cmd.clip_rect.x,
                .y = last_cmd.clip_rect.y,
                .w = last_cmd.clip_rect.w,
                .h = last_cmd.clip_rect.h,
            },
        };
    }
} {
    const vertex_layout = [_]nk.struct_nk_draw_vertex_layout_element{
        nk.struct_nk_draw_vertex_layout_element{
            .attribute = nk.NK_VERTEX_POSITION,
            .format = nk.NK_FORMAT_FLOAT,
            .offset = @offsetOf(Vertex, "pos"),
        },
        nk.struct_nk_draw_vertex_layout_element{
            .attribute = nk.NK_VERTEX_TEXCOORD,
            .format = nk.NK_FORMAT_FLOAT,
            .offset = @offsetOf(Vertex, "uv"),
        },
        nk.struct_nk_draw_vertex_layout_element{
            .attribute = nk.NK_VERTEX_COLOR,
            .format = nk.NK_FORMAT_R8G8B8A8,
            .offset = @offsetOf(Vertex, "color"),
        },
        nk.struct_nk_draw_vertex_layout_element{
            .attribute = nk.NK_VERTEX_ATTRIBUTE_COUNT,
            .format = nk.NK_FORMAT_COUNT,
            .offset = 0,
        },
    };

    const config = nk.struct_nk_convert_config{
        .vertex_layout = @ptrCast(&vertex_layout),
        .vertex_size = @sizeOf(Vertex),
        .vertex_alignment = @alignOf(Vertex),
        .circle_segment_count = 22,
        .curve_segment_count = 22,
        .arc_segment_count = 22,
        .global_alpha = 1.0,
        .shape_AA = nk.NK_ANTI_ALIASING_OFF,
        .line_AA = nk.NK_ANTI_ALIASING_OFF,
    };

    var vbuf: nk.struct_nk_buffer = undefined;
    nk.nk_buffer_init_fixed(
        &vbuf,
        @ptrCast(vertex_buffer_memory.ptr),
        vertex_buffer_memory.len,
    );

    var ibuf: nk.struct_nk_buffer = undefined;
    nk.nk_buffer_init_fixed(
        &ibuf,
        @ptrCast(index_buffer_memory.ptr),
        index_buffer_memory.len,
    );

    _ = nk.nk_convert(
        &self.context,
        &self.cmd_buffer,
        @ptrCast(&vbuf),
        @ptrCast(&ibuf),
        @ptrCast(&config),
    );

    return .{ .cmd = nk.nk__draw_begin(&self.context, &self.cmd_buffer) };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.cmd_buffer_memory);

    nk.nk_free(&self.context);
    allocator.free(self.context_memory);

    allocator.free(self.font_atlas_data);

    nk.nk_font_atlas_clear(&self.font_atlas);
    allocator.free(self.font_atlas_memory);
}

pub fn begin(
    self: *Self,
    name: [*:0]const u8,
    bounds: struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    },
    flags: WindowFlags,
) bool {
    return nk.nk_begin(
        &self.context,
        name,
        nk.nk_rect(
            bounds.x,
            bounds.y,
            bounds.w,
            bounds.h,
        ),
        @bitCast(flags),
    ) != 0;
}

pub fn end(self: *Self) void {
    nk.nk_end(&self.context);
}

pub fn layoutRowStatic(self: *Self, height: f32, item_width: u32, columns: u32) void {
    nk.nk_layout_row_static(
        &self.context,
        height,
        @intCast(item_width),
        @intCast(columns),
    );
}

pub fn layoutRowDynamic(self: *Self, height: f32, columns: u32) void {
    nk.nk_layout_row_dynamic(
        &self.context,
        height,
        @intCast(columns),
    );
}

pub fn label(
    self: *Self,
    text: [*:0]const u8,
    alignment: TextAlignment,
) void {
    nk.nk_label(
        &self.context,
        text,
        @intFromEnum(alignment),
    );
}

pub fn labelFmt(
    self: *Self,
    comptime fmt: []const u8,
    args: anytype,
    alignment: TextAlignment,
) void {
    var buffer: [128]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, fmt, args) catch unreachable;
    self.label(text, alignment);
}

pub fn treePushId(
    self: *Self,
    @"type": TreeType,
    title: [*:0]const u8,
    state: CollapseState,
    source_location: std.builtin.SourceLocation,
    id: u32,
) bool {
    return nk.nk_tree_push_hashed(
        &self.context,
        @intFromEnum(@"type"),
        title,
        @intFromEnum(state),
        std.mem.asBytes(&source_location),
        @sizeOf(std.builtin.SourceLocation),
        @bitCast(id),
    ) != 0;
}

pub fn treePush(
    self: *Self,
    @"type": TreeType,
    title: [*:0]const u8,
    state: CollapseState,
    source_location: std.builtin.SourceLocation,
) bool {
    return self.treePushId(
        @"type",
        title,
        state,
        source_location,
        0,
    );
}

pub fn treePushFmt(
    self: *Self,
    @"type": TreeType,
    comptime fmt: []const u8,
    args: anytype,
    state: CollapseState,
    source_location: std.builtin.SourceLocation,
) bool {
    var buffer: [256]u8 = undefined;
    const title = std.fmt.bufPrintZ(&buffer, fmt, args) catch unreachable;
    return self.treePush(
        @"type",
        title.ptr,
        state,
        source_location,
    );
}

pub fn treePushIdFmt(
    self: *Self,
    @"type": TreeType,
    comptime fmt: []const u8,
    args: anytype,
    state: CollapseState,
    source_location: std.builtin.SourceLocation,
    id: u32,
) bool {
    var buffer: [256]u8 = undefined;
    const title = std.fmt.bufPrintZ(&buffer, fmt, args) catch unreachable;
    return self.treePushId(
        @"type",
        title.ptr,
        state,
        source_location,
        id,
    );
}

pub fn treePop(self: *Self) void {
    nk.nk_tree_pop(&self.context);
}

pub fn groupBegin(self: *Self, title: [*:0]const u8, flags: WindowFlags) bool {
    return nk.nk_group_begin(
        &self.context,
        title,
        @bitCast(flags),
    ) == nk.nk_true;
}

pub fn groupEnd(self: *Self) void {
    nk.nk_group_end(&self.context);
}

pub fn buttonLabel(self: *Self, title: [*:0]const u8) bool {
    return nk.nk_button_label(&self.context, title) == nk.nk_true;
}

pub fn propertyFloat(
    self: *Self,
    name: [*:0]const u8,
    min: f32,
    max: f32,
    step: f32,
    inc_per_pixel: f32,
    val: *f32,
) void {
    nk.nk_property_float(
        &self.context,
        name,
        min,
        @ptrCast(val),
        max,
        step,
        inc_per_pixel,
    );
}

pub fn colorPickRgb(self: *Self, color: *[3]f32) bool {
    return nk.nk_color_pick(&self.context, @ptrCast(color), nk.NK_RGB) == nk.nk_true;
}

pub fn plot(self: *Self, chart_type: ChartType, values: []const f32, offset: u32) void {
    nk.nk_plot(
        &self.context,
        @intFromEnum(chart_type),
        @ptrCast(values.ptr),
        @intCast(values.len),
        @intCast(offset),
    );
}
