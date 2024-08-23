const std = @import("std");

const za = @import("zalgebra");

const Timer = @import("Timer.zig");
const Input = @import("Input.zig");

const Self = @This();

fov: f32,
aspect_ratio: f32,

position: za.Vec3,
rotation: za.Quat,
pitch: f32,
yaw: f32,

forward: za.Vec3,
right: za.Vec3,
up: za.Vec3,

horizontal: za.Vec3,
vertical: za.Vec3,

pub fn new(fov: f32, aspect_ratio: f32, position: za.Vec3) Self {
    var self = Self{
        .fov = fov,
        .aspect_ratio = aspect_ratio,

        .position = position,
        .rotation = za.Quat.identity(),
        .pitch = 0.0,
        .yaw = 0.0,

        .forward = undefined,
        .right = undefined,
        .up = undefined,

        .horizontal = undefined,
        .vertical = undefined,
    };
    self.updateOrientation();
    self.updateVectors();

    return self;
}

pub fn update(self: *Self, input: Input, timer: Timer) void {
    if (input.isMouseButtonPressed(.left)) {
        const rotate_speed: f32 = 0.25;
        if (input.cursor_delta_x != 0.0 or input.cursor_delta_y != 0.0) {
            const cursor_delta_x: f32 = @floatFromInt(input.cursor_delta_x);
            const cursor_delta_y: f32 = @floatFromInt(input.cursor_delta_y);
            self.yaw += cursor_delta_x * rotate_speed;
            self.pitch += cursor_delta_y * rotate_speed;

            if (self.yaw < 0.0) self.yaw += 360.0;
            if (self.yaw >= 360.0) self.yaw -= 360.0;

            self.pitch = std.math.clamp(self.pitch, -90.0, 90.0);

            self.updateOrientation();
            self.updateVectors();
        }
    }

    const move_speed: f32 = if (input.isKeyPressed(.left_shift)) 10.0 else 5.0;
    var dir = za.Vec3.zero();
    if (input.isKeyPressed(.w)) dir = dir.add(self.forward);
    if (input.isKeyPressed(.s)) dir = dir.sub(self.forward);
    if (input.isKeyPressed(.d)) dir = dir.add(self.right);
    if (input.isKeyPressed(.a)) dir = dir.sub(self.right);

    const velocity = dir.norm().scale(move_speed * timer.delta_time);
    self.position = self.position.add(velocity);

    if (input.isKeyPressed(.space)) self.position.data[1] += move_speed * timer.delta_time;
    if (input.isKeyPressed(.left_ctrl)) self.position.data[1] -= move_speed * timer.delta_time;
}

pub fn updateAspectRatio(self: *Self, aspect_ratio: f32) void {
    self.aspect_ratio = aspect_ratio;
    self.updateVectors();
}

fn updateOrientation(self: *Self) void {
    self.rotation = za.Quat.fromAxis(self.yaw, za.Vec3.up()).mul(
        za.Quat.fromAxis(self.pitch, za.Vec3.right()),
    );

    self.forward = self.rotation.rotateVec(za.Vec3.forward());
    self.right = self.rotation.rotateVec(za.Vec3.right());
    self.up = self.forward.cross(self.right);
}

fn updateVectors(self: *Self) void {
    const viewport_height = 2.0 * std.math.tan(self.fov * 0.5);
    const viewport_width = viewport_height * self.aspect_ratio;

    self.horizontal = self.right.scale(viewport_width);
    self.vertical = self.up.scale(viewport_height);
}
