const std = @import("std");

const za = @import("zalgebra");

const Self = @This();

fov: f32,

position: za.Vec3,
pitch: f32,
yaw: f32,

rotation_matrix: za.Mat4,
horizontal: za.Vec3,
vertical: za.Vec3,
forward: za.Vec3,

pub fn new(position: za.Vec3, pitch: f32, yaw: f32, fov: f32) Self {
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

pub fn moveRotated(self: *Self, camera_space_velocity: za.Vec3) void {
    const velocity = self.rotation_matrix.mulByVec4(camera_space_velocity.toVec4(0.0)).toVec3();
    self.position = self.position.add(velocity);
}

pub fn move(self: *Self, velocity: za.Vec3) void {
    self.position = self.position.add(velocity);
}

pub fn update(self: *Self, aspect_ratio: f32) void {
    self.pitch = std.math.clamp(self.pitch, -90.0, 90.0);

    self.rotation_matrix = za.Mat4.fromRotation(
        self.yaw,
        za.Vec3.up(),
    ).rotate(
        self.pitch,
        za.Vec3.right(),
    );

    const viewport_height = 2.0 * std.math.tan(self.fov * 0.5);
    const viewport_width = viewport_height * aspect_ratio;

    self.horizontal = self.rotation_matrix.mulByVec4(za.Vec4.right()).toVec3().norm().scale(-viewport_width);
    self.vertical = self.rotation_matrix.mulByVec4(za.Vec4.up()).toVec3().norm().scale(viewport_height);
    self.forward = self.rotation_matrix.mulByVec4(za.Vec4.forward()).toVec3().norm();
}
