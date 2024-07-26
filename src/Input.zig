const std = @import("std");

const zw = @import("zig-window");

const Self = @This();

cursor_x: f32 = 0.0,
cursor_y: f32 = 0.0,

last_cursor_x: f32 = 0.0,
last_cursor_y: f32 = 0.0,

cursor_delta_x: f32 = 0.0,
cursor_delta_y: f32 = 0.0,

keys: [@intFromEnum(zw.Key.max)]bool = [_]bool{false} ** @intFromEnum(zw.Key.max),
last_keys: [@intFromEnum(zw.Key.max)]bool = [_]bool{false} ** @intFromEnum(zw.Key.max),
mouse_buttons: [@intFromEnum(zw.Mouse.max)]bool = [_]bool{false} ** @intFromEnum(zw.Mouse.max),
last_mouse_buttons: [@intFromEnum(zw.Mouse.max)]bool = [_]bool{false} ** @intFromEnum(zw.Mouse.max),

scroll: f32 = 0.0,
next_scroll: f32 = 0.0,

pub fn handleEvent(self: *Self, event: zw.Event) void {
    switch (event) {
        .KeyPress => |key| self.keys[@intFromEnum(key)] = true,
        .KeyRelease => |key| self.keys[@intFromEnum(key)] = false,
        .MousePress => |button| self.mouse_buttons[@intFromEnum(button)] = true,
        .MouseRelease => |button| self.mouse_buttons[@intFromEnum(button)] = false,
        .MouseMove => |point| {
            const x, const y = point;
            self.cursor_x = @floatFromInt(x);
            self.cursor_y = @floatFromInt(y);
        },
        .MouseScrollV => |y| self.next_scroll = @floatFromInt(y),
        else => {},
    }
}

pub fn update(self: *Self) void {
    self.cursor_delta_x = self.cursor_x - self.last_cursor_x;
    self.cursor_delta_y = self.cursor_y - self.last_cursor_y;

    self.last_cursor_x = self.cursor_x;
    self.last_cursor_y = self.cursor_y;

    self.scroll = self.next_scroll;
    self.next_scroll = 0.0;

    std.mem.copyForwards(bool, &self.last_keys, &self.keys);
    std.mem.copyForwards(bool, &self.last_mouse_buttons, &self.mouse_buttons);
}

pub fn isKeyPressed(self: *const Self, key: zw.Key) bool {
    return self.keys[@intFromEnum(key)];
}

pub fn isKeyReleased(self: *const Self, key: zw.Key) bool {
    return !self.keys[@intFromEnum(key)] and self.last_keys[@intFromEnum(key)];
}

pub fn isMouseButtonPressed(self: *const Self, button: zw.Mouse) bool {
    return self.mouse_buttons[@intFromEnum(button)];
}

pub fn isMouseButtonReleased(self: *const Self, button: zw.Mouse) bool {
    return !self.mouse_buttons[@intFromEnum(button)] and self.last_mouse_buttons[@intFromEnum(button)];
}
