const std = @import("std");

const ShaderCompileStep = @import("vulkan-zig").ShaderCompileStep;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spec_path = b.dependency("vulkan-headers", .{}).path("registry/vk.xml");

    const vk_gen = b.dependency("vulkan-zig", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(spec_path);

    const clap_dep = b.dependency("clap", .{});

    const cgltf_dep = b.dependency("cgltf", .{});
    const cgltf_lib = blk: {
        const cgltf_lib = b.addStaticLibrary(.{
            .name = "cgltf",
            .optimize = optimize,
            .target = target,
        });
        const wf = b.addWriteFiles();
        const cgltf_c = wf.addCopyFile(cgltf_dep.path("cgltf.h"), "cgltf.c");
        cgltf_lib.addCSourceFile(.{
            .file = cgltf_c,
            .flags = &.{"-DCGLTF_IMPLEMENTATION"},
        });
        cgltf_lib.linkLibC();
        break :blk cgltf_lib;
    };

    const stb_dep = b.dependency("stb", .{});
    const stb_image_lib = blk: {
        const stb_image_lib = b.addStaticLibrary(.{
            .name = "stb_image",
            .optimize = optimize,
            .target = target,
        });
        const wf = b.addWriteFiles();
        const stb_c = wf.addCopyFile(stb_dep.path("stb_image.h"), "stb_image.c");
        stb_image_lib.addCSourceFile(.{
            .file = stb_c,
            .flags = &.{"-DSTB_IMAGE_IMPLEMENTATION"},
        });
        stb_image_lib.linkLibC();
        break :blk stb_image_lib;
    };

    const nuklear_dep = b.dependency("nuklear", .{});
    const nuklear_lib = blk: {
        const nuklear_lib = b.addStaticLibrary(.{
            .name = "nuklear",
            .optimize = optimize,
            .target = target,
        });
        const wf = b.addWriteFiles();
        const nuklear_c = wf.addCopyFile(nuklear_dep.path("nuklear.h"), "nuklear.c");
        nuklear_lib.addCSourceFile(.{
            .file = nuklear_c,
            .flags = &.{
                "-DNK_IMPLEMENTATION",
                "-DNK_INCLUDE_DEFAULT_FONT",
                "-DNK_INCLUDE_FONT_BAKING",
                "-DNK_INCLUDE_VERTEX_BUFFER_OUTPUT",
            },
        });
        nuklear_lib.linkLibC();
        break :blk nuklear_lib;
    };

    const exe = b.addExecutable(.{
        .name = "vulkan-pathtracer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addAnonymousImport("vulkan", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.linkSystemLibrary("glfw");
    exe.linkLibrary(cgltf_lib);
    exe.addIncludePath(cgltf_dep.path(""));
    exe.linkLibrary(stb_image_lib);
    exe.addIncludePath(stb_dep.path(""));
    exe.linkLibrary(nuklear_lib);
    exe.addIncludePath(nuklear_dep.path(""));
    b.installArtifact(exe);

    const shaders = ShaderCompileStep.create(
        b,
        &[_][]const u8{ "glslc", "--target-env=vulkan1.2" },
        "-o",
    );
    shaders.add("ray_gen", "src/shaders/ray_gen.rgen", .{});
    shaders.add("miss", "src/shaders/miss.rmiss", .{});
    shaders.add("closest_hit", "src/shaders/closest_hit.rchit", .{});
    shaders.add("nuklear_vert", "src/shaders/nuklear.vert", .{});
    shaders.add("nuklear_frag", "src/shaders/nuklear.frag", .{});
    exe.root_module.addImport("shaders", shaders.getModule());

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
