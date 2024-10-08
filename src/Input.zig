const std = @import("std");

const zw = @import("zig-window");

pub const Key = zw.Key;
pub const Mouse = zw.Mouse;

const Self = @This();

cursor_x: i32 = 0,
cursor_y: i32 = 0,

last_cursor_x: i32 = 0,
last_cursor_y: i32 = 0,

cursor_delta_x: i32 = 0,
cursor_delta_y: i32 = 0,

keys: [@intFromEnum(Key.max)]bool = [_]bool{false} ** @intFromEnum(Key.max),
last_keys: [@intFromEnum(Key.max)]bool = [_]bool{false} ** @intFromEnum(Key.max),
mouse_buttons: [@intFromEnum(Mouse.max)]bool = [_]bool{false} ** @intFromEnum(Mouse.max),
last_mouse_buttons: [@intFromEnum(Mouse.max)]bool = [_]bool{false} ** @intFromEnum(Mouse.max),

scroll: i32 = 0,
next_scroll: i32 = 0,

pub fn handleEvent(self: *Self, event: zw.Event) void {
    switch (event) {
        .KeyPress => |key| self.keys[@intFromEnum(key)] = true,
        .KeyRelease => |key| self.keys[@intFromEnum(key)] = false,
        .MousePress => |button| self.mouse_buttons[@intFromEnum(button)] = true,
        .MouseRelease => |button| self.mouse_buttons[@intFromEnum(button)] = false,
        .MouseMove => |point| {
            self.cursor_x, self.cursor_y = point;
        },
        .MouseScrollV => |y| self.next_scroll += y,
        else => {},
    }
}

pub fn reset(self: *Self) void {
    self.cursor_delta_x = self.cursor_x - self.last_cursor_x;
    self.cursor_delta_y = self.cursor_y - self.last_cursor_y;

    self.last_cursor_x = self.cursor_x;
    self.last_cursor_y = self.cursor_y;

    self.scroll = self.next_scroll;
    self.next_scroll = 0;

    std.mem.copyForwards(bool, &self.last_keys, &self.keys);
    std.mem.copyForwards(bool, &self.last_mouse_buttons, &self.mouse_buttons);
}

pub fn isKeyPressed(self: *const Self, key: Key) bool {
    return self.keys[@intFromEnum(key)];
}

pub fn isKeyReleased(self: *const Self, key: Key) bool {
    return !self.keys[@intFromEnum(key)] and self.last_keys[@intFromEnum(key)];
}

pub fn isKeyJustPressed(self: *const Self, key: Key) bool {
    return self.keys[@intFromEnum(key)] and !self.last_keys[@intFromEnum(key)];
}

pub fn isMouseButtonPressed(self: *const Self, button: Mouse) bool {
    return self.mouse_buttons[@intFromEnum(button)];
}

pub fn isMouseButtonReleased(self: *const Self, button: Mouse) bool {
    return !self.mouse_buttons[@intFromEnum(button)] and self.last_mouse_buttons[@intFromEnum(button)];
}

pub fn isMouseButtonJustPressed(self: *const Self, button: Mouse) bool {
    return self.mouse_buttons[@intFromEnum(button)] and !self.last_mouse_buttons[@intFromEnum(button)];
}
