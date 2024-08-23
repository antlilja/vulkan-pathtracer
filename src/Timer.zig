const std = @import("std");

const Self = @This();

time: std.time.Instant,
delta_time: f32 = 0.0,

second_time: std.time.Instant,
second_elapsed: bool = false,

pub fn start() Self {
    const now = std.time.Instant.now() catch unreachable;
    return .{
        .time = now,
        .second_time = now,
    };
}

pub fn lap(self: *Self) void {
    const now = std.time.Instant.now() catch unreachable;
    self.delta_time = @as(f32, @floatFromInt(now.since(self.time))) / @as(f32, @floatFromInt(std.time.ns_per_s));
    self.time = now;

    if (now.since(self.second_time) >= std.time.ns_per_s) {
        self.second_time = now;
        self.second_elapsed = true;
    } else self.second_elapsed = false;
}
