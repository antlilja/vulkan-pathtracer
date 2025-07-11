const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spec_path = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");

    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(spec_path);

    const zw_dep = b.dependency("zig_window", .{
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

    const nuklear_mod = compileCHeaderOnlyLib(
        b,
        target,
        optimize,
        b.dependency("nuklear", .{}),
        "nuklear",
        "nuklear.h",
        &.{
            "NK_INCLUDE_FIXED_TYPES",
            "NK_INCLUDE_DEFAULT_FONT",
            "NK_INCLUDE_FONT_BAKING",
            "NK_INCLUDE_VERTEX_BUFFER_OUTPUT",
        },
        &.{
            "-DNK_IMPLEMENTATION",
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
    exe.root_module.addImport("nuklear", nuklear_mod);
    b.installArtifact(exe);

    const shader_compiler = b.dependency("shader_compiler", .{
        .target = std.Build.resolveTargetQuery(b, .{
            .cpu_model = .native,
        }),
        .optimize = .ReleaseSafe,
    }).artifact("shader_compiler");

    compileShader(
        b,
        exe.root_module,
        shader_compiler,
        b.path("src/shaders/ray_gen.rgen"),
        "ray_gen",
    );
    compileShader(
        b,
        exe.root_module,
        shader_compiler,
        b.path("src/shaders/miss.rmiss"),
        "miss",
    );
    compileShader(
        b,
        exe.root_module,
        shader_compiler,
        b.path("src/shaders/closest_hit.rchit"),
        "closest_hit",
    );
    compileShader(
        b,
        exe.root_module,
        shader_compiler,
        b.path("src/shaders/nuklear.vert"),
        "nuklear_vert",
    );
    compileShader(
        b,
        exe.root_module,
        shader_compiler,
        b.path("src/shaders/nuklear.frag"),
        "nuklear_frag",
    );

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn compileShader(
    b: *std.Build,
    module: *std.Build.Module,
    compiler_artifact: *std.Build.Step.Compile,
    src: std.Build.LazyPath,
    name: []const u8,
) void {
    const cmd = b.addRunArtifact(compiler_artifact);
    cmd.addArgs(&.{ "--target", "Vulkan-1.2", "--optimize-perf", "--scalar-block-layout" });
    cmd.addArg("--include-path");
    cmd.addDirectoryArg(b.path("src/shaders"));
    cmd.addArg("--write-deps");
    _ = cmd.addDepFileOutputArg("deps.d");
    cmd.addFileArg(src);
    const spv = cmd.addOutputFileArg(std.mem.concat(
        b.allocator,
        u8,
        &.{ name, ".spv" },
    ) catch unreachable);
    module.addAnonymousImport(name, .{
        .root_source_file = spv,
    });
}

fn compileCHeaderOnlyLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: *std.Build.Dependency,
    lib_name: []const u8,
    header_file_path: []const u8,
    common_defines: []const []const u8,
    impl_flags: []const []const u8,
) *std.Build.Module {
    const header_path = dependency.path(header_file_path);

    const translate_c = b.addTranslateC(.{
        .root_source_file = header_path,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (common_defines) |define| {
        translate_c.defineCMacro(define, null);
    }

    const c_file_path = b.allocator.alloc(u8, header_file_path.len) catch unreachable;
    _ = std.mem.replace(u8, header_file_path, ".h", ".c", c_file_path);

    const wf = b.addWriteFiles();
    const c_file = wf.addCopyFile(dependency.path(header_file_path), c_file_path);

    const flags = b.allocator.alloc([]const u8, common_defines.len + impl_flags.len) catch unreachable;
    for (common_defines, flags[0..common_defines.len]) |define, *flag| {
        flag.* = std.mem.concat(b.allocator, u8, &.{ "-D", define }) catch unreachable;
    }

    for (impl_flags, flags[common_defines.len..]) |impl_flag, *flag| {
        flag.* = impl_flag;
    }

    const lib = b.addStaticLibrary(.{
        .name = lib_name,
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });
    lib.addCSourceFile(.{
        .file = c_file,
        .flags = flags,
    });

    const mod = translate_c.createModule();
    mod.linkLibrary(lib);

    return mod;
}
