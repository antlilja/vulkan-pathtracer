const std = @import("std");

const glfw = @import("glfw.zig");

const Self = @This();

pub const Key = enum(c_int) {
    a = glfw.GLFW_KEY_A,
    b = glfw.GLFW_KEY_B,
    c = glfw.GLFW_KEY_C,
    d = glfw.GLFW_KEY_D,
    e = glfw.GLFW_KEY_E,
    f = glfw.GLFW_KEY_F,
    g = glfw.GLFW_KEY_G,
    h = glfw.GLFW_KEY_H,
    i = glfw.GLFW_KEY_I,
    j = glfw.GLFW_KEY_J,
    k = glfw.GLFW_KEY_K,
    l = glfw.GLFW_KEY_L,
    m = glfw.GLFW_KEY_M,
    n = glfw.GLFW_KEY_N,
    o = glfw.GLFW_KEY_O,
    p = glfw.GLFW_KEY_P,
    q = glfw.GLFW_KEY_Q,
    r = glfw.GLFW_KEY_R,
    s = glfw.GLFW_KEY_S,
    t = glfw.GLFW_KEY_T,
    u = glfw.GLFW_KEY_U,
    v = glfw.GLFW_KEY_V,
    w = glfw.GLFW_KEY_W,
    x = glfw.GLFW_KEY_X,
    y = glfw.GLFW_KEY_Y,
    z = glfw.GLFW_KEY_Z,
    left_shift = glfw.GLFW_KEY_LEFT_SHIFT,
    right_shift = glfw.GLFW_KEY_RIGHT_SHIFT,
    left_control = glfw.GLFW_KEY_LEFT_CONTROL,
    right_control = glfw.GLFW_KEY_RIGHT_CONTROL,
    space = glfw.GLFW_KEY_SPACE,
};

pub const MouseButton = enum(c_int) {
    left = glfw.GLFW_MOUSE_BUTTON_LEFT,
    right = glfw.GLFW_MOUSE_BUTTON_RIGHT,
    middle = glfw.GLFW_MOUSE_BUTTON_MIDDLE,
};

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

pub fn isKeyPressed(self: *const Self, key: Key) bool {
    return glfw.glfwGetKey(self.window, @intFromEnum(key)) == glfw.GLFW_PRESS;
}

pub fn isKeyReleased(self: *const Self, key: Key) bool {
    return glfw.glfwGetKey(self.window, @intFromEnum(key)) == glfw.GLFW_RELEASE;
}

pub fn isMouseButtonPressed(self: *const Self, button: MouseButton) bool {
    return glfw.glfwGetMouseButton(self.window, @intFromEnum(button)) == glfw.GLFW_PRESS;
}

pub fn isMouseButtonReleased(self: *const Self, button: MouseButton) bool {
    return glfw.glfwGetMouseButton(self.window, @intFromEnum(button)) == glfw.GLFW_RELEASE;
}
