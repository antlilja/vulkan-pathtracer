const std = @import("std");

const ShaderCompileStep = @import("vulkan-zig").ShaderCompileStep;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spec_path = b.dependency("vulkan-headers", .{}).path("registry/vk.xml");

    const vk_gen = b.dependency("vulkan-zig", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(spec_path);

    const zw_dep = b.dependency("zig-window", .{
        .target = target,
        .optimize = optimize,
    });

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const zi_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const nuklear_lib = compileCHeaderOnlyLib(
        b,
        target,
        optimize,
        "nuklear",
        "nuklear.h",
        "",
        &.{
            "-DNK_IMPLEMENTATION",
            "-DNK_INCLUDE_FIXED_TYPES",
            "-DNK_INCLUDE_DEFAULT_FONT",
            "-DNK_INCLUDE_FONT_BAKING",
            "-DNK_INCLUDE_VERTEX_BUFFER_OUTPUT",
        },
    );

    const exe = b.addExecutable(.{
        .name = "vulkan-pathtracer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.root_module.addAnonymousImport("vulkan", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });
    exe.root_module.addImport("zig-window", zw_dep.module("zig-window"));
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.root_module.addImport("zigimg", zi_dep.module("zigimg"));
    exe.root_module.addImport("zgltf", b.dependency("zgltf", .{
        .target = target,
        .optimize = optimize,
    }).module("zgltf"));
    exe.root_module.addImport("zalgebra", b.dependency("zalgebra", .{
        .target = target,
        .optimize = optimize,
    }).module("zalgebra"));
    exe.linkLibrary(nuklear_lib);
    b.installArtifact(exe);

    const glslang = b.dependency("glslang", .{
        .target = std.Build.resolveTargetQuery(b, .{
            .cpu_model = .native,
        }),
        .optimize = .ReleaseSafe,
    }).artifact("glslang");

    const shaders = ShaderCompileStep.create(
        b,
        .{ .lazy_path = glslang.getEmittedBin() },
        &[_][]const u8{ "-V", "--target-env", "vulkan1.2" },
        "-o",
    );
    shaders.add("ray_gen", "src/shaders/ray_gen.rgen", .{});
    shaders.add("miss", "src/shaders/miss.rmiss", .{});
    shaders.add("closest_hit", "src/shaders/closest_hit.rchit", .{});
    shaders.add("nuklear_vert", "src/shaders/nuklear.vert", .{});
    shaders.add("nuklear_frag", "src/shaders/nuklear.frag", .{});
    exe.root_module.addImport("shaders", shaders.getModule());
    shaders.step.dependOn(&glslang.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn compileCHeaderOnlyLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    header_file_path: []const u8,
    include_dir: []const u8,
    flags: []const []const u8,
) *std.Build.Step.Compile {
    const dep = b.dependency(name, .{});
    const lib = b.addStaticLibrary(.{
        .name = name,
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const c_file_path = b.allocator.alloc(u8, header_file_path.len) catch unreachable;
    _ = std.mem.replace(u8, header_file_path, ".h", ".c", c_file_path);

    const wf = b.addWriteFiles();
    const c_file = wf.addCopyFile(dep.path(header_file_path), c_file_path);
    lib.addCSourceFile(.{
        .file = c_file,
        .flags = flags,
    });

    lib.installHeadersDirectory(dep.path(include_dir), include_dir, .{});

    return lib;
}
