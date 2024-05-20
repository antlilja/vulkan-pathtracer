const std = @import("std");

const Vec3 = @import("Vec3.zig");
const Mat4 = @import("Mat4.zig");

const Self = @This();

fov: f32,

position: Vec3,
pitch: f32,
yaw: f32,

rotation_matrix: Mat4,
horizontal: Vec3,
vertical: Vec3,
forward: Vec3,

pub fn new(position: Vec3, pitch: f32, yaw: f32, fov: f32) Self {
    return Self{
        .fov = fov,

        .position = position,
        .pitch = pitch,
        .yaw = yaw,

        .rotation_matrix = undefined,
        .horizontal = undefined,
        .vertical = undefined,
        .forward = undefined,
    };
}

pub fn moveRotated(self: *Self, camera_space_velocity: Vec3) void {
    const velocity = camera_space_velocity.transformDirection(self.rotation_matrix);
    self.position = self.position.add(velocity);
}

pub fn move(self: *Self, velocity: Vec3) void {
    self.position = self.position.add(velocity);
}

pub fn update(self: *Self, aspect_ratio: f32) void {
    self.pitch = std.math.clamp(self.pitch, -std.math.pi * 0.5, std.math.pi * 0.5);

    self.rotation_matrix = Mat4.angleAxis(
        Vec3.unit_y,
        self.yaw,
    ).mul(Mat4.angleAxis(
        Vec3.unit_x,
        self.pitch,
    ));

    const viewport_height = 2.0 * std.math.tan(self.fov * 0.5);
    const viewport_width = viewport_height * aspect_ratio;

    self.horizontal = Vec3.unit_x.transformDirection(self.rotation_matrix).scale(-viewport_width);
    self.vertical = Vec3.unit_y.transformDirection(self.rotation_matrix).scale(viewport_height);
    self.forward = Vec3.unit_z.transformDirection(self.rotation_matrix);
}
