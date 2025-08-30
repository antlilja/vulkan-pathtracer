const std = @import("std");
const vk = @import("vulkan");

arena: std.heap.ArenaAllocator,
base: *const anyopaque,

pub fn init(
    extra_features: anytype,
    allocator: std.mem.Allocator,
) !@This() {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const GenericFeatures = extern struct {
        s_type: vk.StructureType,
        p_next: ?*const @This(),
    };
    const fields = std.meta.fields(@TypeOf(extra_features));

    var skip_list = [_]bool{false} ** fields.len;

    const features2 = try arena_allocator.create(vk.PhysicalDeviceFeatures2);
    features2.* = .{ .features = .{} };

    var base: *GenericFeatures = @ptrCast(features2);

    inline for (fields, 0..) |field, i| {
        if (field.type == vk.PhysicalDeviceFeatures) {
            inline for (std.meta.fields(vk.PhysicalDeviceFeatures)) |feature_field| {
                @field(features2.features, feature_field.name) =
                    if (@field(@field(extra_features, field.name), feature_field.name) == .true or
                    @field(features2.features, feature_field.name) == .true) .true else .false;
            }
        } else if (field.type == vk.PhysicalDeviceFeatures2) {
            @compileError("Not allowed to pass vk.PhysicalDeviceFeatures2");
        } else if (!skip_list[i]) {
            const features_ptr = try arena_allocator.create(field.type);
            features_ptr.* = @field(extra_features, field.name);
            inline for (fields, 0..) |other_field, j| {
                if (field.type == other_field.type) {
                    const feature_fields = std.meta.fields(field.type);
                    inline for (feature_fields) |feature_field| {
                        if (feature_field.type == vk.Bool32) {
                            @field(features_ptr.*, feature_field.name) =
                                if (@field(features_ptr.*, feature_field.name) == .true or
                                @field(@field(extra_features, other_field.name), feature_field.name) == .true) .true else .false;
                        }
                    }

                    skip_list[j] = true;
                }
            }

            const generic_ptr: *GenericFeatures = @ptrCast(@alignCast(features_ptr));
            generic_ptr.p_next = base;
            base = generic_ptr;
        }
    }

    return .{
        .arena = arena,
        .base = @ptrCast(base),
    };
}

pub fn deinit(self: @This()) void {
    self.arena.deinit();
}
