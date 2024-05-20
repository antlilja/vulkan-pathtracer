const std = @import("std");
const Self = @This();

const Vec3 = @import("Vec3.zig");

elements: [16]f32,

pub fn identity() Self {
    return .{
        .elements = .{
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        },
    };
}

pub fn translation(x: f32, y: f32, z: f32) Self {
    return .{
        .elements = .{
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            x,   y,   z,   1.0,
        },
    };
}

pub fn scaling(x: f32, y: f32, z: f32) Self {
    return .{
        .elements = .{
            x,   0.0, 0.0, 0.0,
            0.0, y,   0.0, 0.0,
            0.0, 0.0, z,   0.0,
            0.0, 0.0, 0.0, 1.0,
        },
    };
}

pub fn angleAxis(axis: Vec3, angle: f32) Self {
    const cos = @cos(angle);
    const sin = @sin(angle);

    const normalized = axis.normalize();
    const x = normalized.x;
    const y = normalized.y;
    const z = normalized.z;

    return .{
        .elements = .{
            cos + x * x * (1 - cos),     x * y * (1 - cos) + z * sin, x * z * (1 - cos) - y * sin, 0,
            y * x * (1 - cos) - z * sin, cos + y * y * (1 - cos),     y * z * (1 - cos) + x * sin, 0,
            z * x * (1 - cos) + y * sin, z * y * (1 - cos) - x * sin, cos + z * z * (1 - cos),     0,
            0,                           0,                           0,                           1,
        },
    };
}

pub fn rotationFromQuaternion(q: [4]f32) Self {
    const r00 = 2.0 * (q[0] * q[0] + q[1] * q[1]) - 1.0;
    const r01 = 2.0 * (q[1] * q[2] - q[0] * q[3]);
    const r02 = 2.0 * (q[1] * q[3] + q[0] * q[2]);

    const r10 = 2.0 * (q[1] * q[2] + q[0] * q[3]);
    const r11 = 2.0 * (q[0] * q[0] + q[2] * q[2]) - 1.0;
    const r12 = 2.0 * (q[2] * q[3] - q[0] * q[1]);

    const r20 = 2.0 * (q[1] * q[3] - q[0] * q[2]);
    const r21 = 2.0 * (q[2] * q[3] + q[0] * q[1]);
    const r22 = 2.0 * (q[0] * q[0] + q[3] * q[3]) - 1.0;

    return .{
        .elements = .{
            r00, r10, r20, 0.0,
            r01, r11, r21, 0.0,
            r02, r12, r22, 0.0,
            0.0, 0.0, 0.0, 1.0,
        },
    };
}

pub fn at(self: Self, col: usize, row: usize) f32 {
    return self.elements[row + col * 4];
}

pub fn set(self: *Self, col: usize, row: usize, val: f32) void {
    self.elements[row + col * 4] = val;
}

pub fn scale(self: Self, scalar: f32) Self {
    var new = self;
    for (&new.elements) |*e| {
        e.* *= scalar;
    }
    return new;
}

pub fn inverse(self: Self) Self {
    var inv: Self = undefined;
    inv.elements[0] = self.elements[5] * self.elements[10] * self.elements[15] -
        self.elements[5] * self.elements[11] * self.elements[14] -
        self.elements[9] * self.elements[6] * self.elements[15] +
        self.elements[9] * self.elements[7] * self.elements[14] +
        self.elements[13] * self.elements[6] * self.elements[11] -
        self.elements[13] * self.elements[7] * self.elements[10];

    inv.elements[4] = -self.elements[4] * self.elements[10] * self.elements[15] +
        self.elements[4] * self.elements[11] * self.elements[14] +
        self.elements[8] * self.elements[6] * self.elements[15] -
        self.elements[8] * self.elements[7] * self.elements[14] -
        self.elements[12] * self.elements[6] * self.elements[11] +
        self.elements[12] * self.elements[7] * self.elements[10];

    inv.elements[8] = self.elements[4] * self.elements[9] * self.elements[15] -
        self.elements[4] * self.elements[11] * self.elements[13] -
        self.elements[8] * self.elements[5] * self.elements[15] +
        self.elements[8] * self.elements[7] * self.elements[13] +
        self.elements[12] * self.elements[5] * self.elements[11] -
        self.elements[12] * self.elements[7] * self.elements[9];

    inv.elements[12] = -self.elements[4] * self.elements[9] * self.elements[14] +
        self.elements[4] * self.elements[10] * self.elements[13] +
        self.elements[8] * self.elements[5] * self.elements[14] -
        self.elements[8] * self.elements[6] * self.elements[13] -
        self.elements[12] * self.elements[5] * self.elements[10] +
        self.elements[12] * self.elements[6] * self.elements[9];

    inv.elements[1] = -self.elements[1] * self.elements[10] * self.elements[15] +
        self.elements[1] * self.elements[11] * self.elements[14] +
        self.elements[9] * self.elements[2] * self.elements[15] -
        self.elements[9] * self.elements[3] * self.elements[14] -
        self.elements[13] * self.elements[2] * self.elements[11] +
        self.elements[13] * self.elements[3] * self.elements[10];

    inv.elements[5] = self.elements[0] * self.elements[10] * self.elements[15] -
        self.elements[0] * self.elements[11] * self.elements[14] -
        self.elements[8] * self.elements[2] * self.elements[15] +
        self.elements[8] * self.elements[3] * self.elements[14] +
        self.elements[12] * self.elements[2] * self.elements[11] -
        self.elements[12] * self.elements[3] * self.elements[10];

    inv.elements[9] = -self.elements[0] * self.elements[9] * self.elements[15] +
        self.elements[0] * self.elements[11] * self.elements[13] +
        self.elements[8] * self.elements[1] * self.elements[15] -
        self.elements[8] * self.elements[3] * self.elements[13] -
        self.elements[12] * self.elements[1] * self.elements[11] +
        self.elements[12] * self.elements[3] * self.elements[9];

    inv.elements[13] = self.elements[0] * self.elements[9] * self.elements[14] -
        self.elements[0] * self.elements[10] * self.elements[13] -
        self.elements[8] * self.elements[1] * self.elements[14] +
        self.elements[8] * self.elements[2] * self.elements[13] +
        self.elements[12] * self.elements[1] * self.elements[10] -
        self.elements[12] * self.elements[2] * self.elements[9];

    inv.elements[2] = self.elements[1] * self.elements[6] * self.elements[15] -
        self.elements[1] * self.elements[7] * self.elements[14] -
        self.elements[5] * self.elements[2] * self.elements[15] +
        self.elements[5] * self.elements[3] * self.elements[14] +
        self.elements[13] * self.elements[2] * self.elements[7] -
        self.elements[13] * self.elements[3] * self.elements[6];

    inv.elements[6] = -self.elements[0] * self.elements[6] * self.elements[15] +
        self.elements[0] * self.elements[7] * self.elements[14] +
        self.elements[4] * self.elements[2] * self.elements[15] -
        self.elements[4] * self.elements[3] * self.elements[14] -
        self.elements[12] * self.elements[2] * self.elements[7] +
        self.elements[12] * self.elements[3] * self.elements[6];

    inv.elements[10] = self.elements[0] * self.elements[5] * self.elements[15] -
        self.elements[0] * self.elements[7] * self.elements[13] -
        self.elements[4] * self.elements[1] * self.elements[15] +
        self.elements[4] * self.elements[3] * self.elements[13] +
        self.elements[12] * self.elements[1] * self.elements[7] -
        self.elements[12] * self.elements[3] * self.elements[5];

    inv.elements[14] = -self.elements[0] * self.elements[5] * self.elements[14] +
        self.elements[0] * self.elements[6] * self.elements[13] +
        self.elements[4] * self.elements[1] * self.elements[14] -
        self.elements[4] * self.elements[2] * self.elements[13] -
        self.elements[12] * self.elements[1] * self.elements[6] +
        self.elements[12] * self.elements[2] * self.elements[5];

    inv.elements[3] = -self.elements[1] * self.elements[6] * self.elements[11] +
        self.elements[1] * self.elements[7] * self.elements[10] +
        self.elements[5] * self.elements[2] * self.elements[11] -
        self.elements[5] * self.elements[3] * self.elements[10] -
        self.elements[9] * self.elements[2] * self.elements[7] +
        self.elements[9] * self.elements[3] * self.elements[6];

    inv.elements[7] = self.elements[0] * self.elements[6] * self.elements[11] -
        self.elements[0] * self.elements[7] * self.elements[10] -
        self.elements[4] * self.elements[2] * self.elements[11] +
        self.elements[4] * self.elements[3] * self.elements[10] +
        self.elements[8] * self.elements[2] * self.elements[7] -
        self.elements[8] * self.elements[3] * self.elements[6];

    inv.elements[11] = -self.elements[0] * self.elements[5] * self.elements[11] +
        self.elements[0] * self.elements[7] * self.elements[9] +
        self.elements[4] * self.elements[1] * self.elements[11] -
        self.elements[4] * self.elements[3] * self.elements[9] -
        self.elements[8] * self.elements[1] * self.elements[7] +
        self.elements[8] * self.elements[3] * self.elements[5];

    inv.elements[15] = self.elements[0] * self.elements[5] * self.elements[10] -
        self.elements[0] * self.elements[6] * self.elements[9] -
        self.elements[4] * self.elements[1] * self.elements[10] +
        self.elements[4] * self.elements[2] * self.elements[9] +
        self.elements[8] * self.elements[1] * self.elements[6] -
        self.elements[8] * self.elements[2] * self.elements[5];

    const det = self.elements[0] * inv.elements[0] + self.elements[1] * inv.elements[4] + self.elements[2] * inv.elements[8] + self.elements[3] * inv.elements[12];
    const inv_det = 1.0 / det;

    for (&inv.elements) |*e| {
        e.* *= inv_det;
    }
    return inv;
}

pub fn transpose(a: Self) Self {
    var result: Self = undefined;
    inline for (0..4) |row| {
        inline for (0..4) |col| {
            result.set(col, row, a.at(row, col));
        }
    }
    return result;
}

pub fn mul(self: Self, other: Self) Self {
    var new: Self = undefined;

    for (0..4) |r| {
        for (0..4) |c| {
            var sum: f32 = 0.0;
            for (0..4) |k| {
                sum += self.at(k, r) * other.at(c, k);
            }
            new.set(c, r, sum);
        }
    }
    return new;
}
