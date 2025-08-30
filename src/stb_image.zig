const std = @import("std");

pub fn load_from_memory_rgba(buffer: []const u8) !struct {
    image: []const u8,
    width: u32,
    height: u32,
} {
    var width_int: c_int = undefined;
    var height_int: c_int = undefined;
    var components: c_int = 4;
    const image = stbi_load_from_memory(
        buffer.ptr,
        @intCast(buffer.len),
        &width_int,
        &height_int,
        &components,
        4,
    ) orelse return error.LoadFailed;

    const width: u32 = @intCast(width_int);
    const height: u32 = @intCast(height_int);

    return .{
        .image = image[0..(width * height * 4)],
        .width = width,
        .height = height,
    };
}

extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    comp: *c_int,
    req_comp: c_int,
) callconv(.c) ?[*]u8;
