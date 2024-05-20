const std = @import("std");
const math = std.math;

const Mat4 = @import("Mat4.zig");

const Self = @This();

x: f32,
y: f32,
z: f32,

pub const zero = splat(0.0);
pub const unit_x = new(1.0, 0.0, 0.0);
pub const unit_y = new(0.0, 1.0, 0.0);
pub const unit_z = new(0.0, 0.0, 1.0);

pub fn new(x: f32, y: f32, z: f32) Self {
    return .{
        .x = x,
        .y = y,
        .z = z,
    };
}

pub fn splat(scalar: f32) Self {
    return .{
        .x = scalar,
        .y = scalar,
        .z = scalar,
    };
}

pub fn add(self: Self, other: Self) Self {
    return .{
        .x = self.x + other.x,
        .y = self.y + other.y,
        .z = self.z + other.z,
    };
}

pub fn sub(self: Self, other: Self) Self {
    return .{
        .x = self.x - other.x,
        .y = self.y - other.y,
        .z = self.z - other.z,
    };
}

pub fn mul(self: Self, other: Self) Self {
    return .{
        .x = self.x * other.x,
        .y = self.y * other.y,
        .z = self.z * other.z,
    };
}

pub fn scale(self: Self, scalar: f32) Self {
    return .{
        .x = self.x * scalar,
        .y = self.y * scalar,
        .z = self.z * scalar,
    };
}

pub fn dot(self: Self, other: Self) f32 {
    return self.x * other.x + self.y * other.y + self.z * other.z;
}

pub fn cross(self: Self, other: Self) Self {
    return .{
        .x = self.y * other.z - self.z * other.y,
        .y = self.z * other.x - self.x * other.z,
        .z = self.x * other.y - self.y * other.x,
    };
}

pub fn normalize(self: Self) Self {
    const l = self.len();
    return .{
        .x = self.x / l,
        .y = self.y / l,
        .z = self.z / l,
    };
}

pub fn len(self: Self) f32 {
    return math.sqrt(self.squareLen());
}

pub fn squareLen(self: Self) f32 {
    return self.dot(self);
}

pub fn sqrt(self: Self) Self {
    return .{
        .x = @sqrt(self.x),
        .y = @sqrt(self.y),
        .z = @sqrt(self.z),
    };
}

pub fn eql(self: Self, other: Self) bool {
    return self.x == other.x and self.y == other.y and self.z == other.z;
}

pub fn lerp(self: Self, other: Self, scalar: f32) Self {
    return self.scale(1.0 - scalar).add(other.scale(scalar));
}

pub fn transformPosition(self: Self, m: Mat4) Self {
    return .{
        .x = self.x * m.at(0, 0) + self.y * m.at(1, 0) + self.z * m.at(2, 0) + m.at(3, 0),
        .y = self.x * m.at(0, 1) + self.y * m.at(1, 1) + self.z * m.at(2, 1) + m.at(3, 1),
        .z = self.x * m.at(0, 2) + self.y * m.at(1, 2) + self.z * m.at(2, 2) + m.at(3, 2),
    };
}

pub fn transformDirection(self: Self, m: Mat4) Self {
    return .{
        .x = self.x * m.at(0, 0) + self.y * m.at(1, 0) + self.z * m.at(2, 0),
        .y = self.x * m.at(0, 1) + self.y * m.at(1, 1) + self.z * m.at(2, 1),
        .z = self.x * m.at(0, 2) + self.y * m.at(1, 2) + self.z * m.at(2, 2),
    };
}
