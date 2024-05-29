const std = @import("std");

const glfw = @import("glfw.zig");

const Self = @This();

window: *glfw.GLFWwindow,

cursor_x: f64,
cursor_y: f64,

cursor_delta_x: f64,
cursor_delta_y: f64,

pub fn init(window: *glfw.GLFWwindow) Self {
    var cursor_x: f64 = undefined;
    var cursor_y: f64 = undefined;
    glfw.glfwGetCursorPos(window, &cursor_x, &cursor_y);

    return .{
        .window = window,

        .cursor_x = cursor_x,
        .cursor_y = cursor_y,
        .cursor_delta_x = 0.0,
        .cursor_delta_y = 0.0,
    };
}

pub fn update(self: *Self) void {
    var new_cursor_x: f64 = undefined;
    var new_cursor_y: f64 = undefined;
    glfw.glfwGetCursorPos(self.window, &new_cursor_x, &new_cursor_y);

    self.cursor_delta_x = new_cursor_x - self.cursor_x;
    self.cursor_delta_y = new_cursor_y - self.cursor_y;

    self.cursor_x = new_cursor_x;
    self.cursor_y = new_cursor_y;
}

pub fn isKeyPressed(self: *Self, key: c_int) bool {
    return glfw.glfwGetKey(self.window, key) == glfw.GLFW_PRESS;
}

pub fn isKeyReleased(self: *Self, key: c_int) bool {
    return glfw.glfwGetKey(self.window, key) == glfw.GLFW_RELEASE;
}

pub fn isMouseButtonPressed(self: *Self, button: c_int) bool {
    return glfw.glfwGetMouseButton(self.window, button) == glfw.GLFW_PRESS;
}

pub fn isMouseButtonReleased(self: *Self, button: c_int) bool {
    return glfw.glfwGetMouseButton(self.window, button) == glfw.GLFW_RELEASE;
}
