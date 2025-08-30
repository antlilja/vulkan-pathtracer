const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spec_path = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");

    const vulkan_mod = blk: {
        const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
        const vk_generate_cmd = b.addRunArtifact(vk_gen);
        vk_generate_cmd.addFileArg(spec_path);

        break :blk b.createModule(.{ .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig") });
    };

    const nuklear_mod = blk: {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.dependency("nuklear", .{}).path("nuklear.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_c.defineCMacroRaw("NK_INCLUDE_FIXED_TYPES=1");
        translate_c.defineCMacroRaw("NK_INCLUDE_DEFAULT_FONT=1");
        translate_c.defineCMacroRaw("NK_INCLUDE_FONT_BAKING=1");
        translate_c.defineCMacroRaw("NK_INCLUDE_VERTEX_BUFFER_OUTPUT=");
        break :blk translate_c.createModule();
    };

    const exe = b.addExecutable(.{
        .name = "vulkan-pathtracer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vulkan", .module = vulkan_mod },
                .{ .name = "zig-window", .module = b.dependency("zig_window", .{}).module("zig-window") },
                .{ .name = "structopt", .module = b.dependency("structopt", .{}).module("structopt") },
                .{ .name = "zgltf", .module = b.dependency("zgltf", .{}).module("zgltf") },
                .{ .name = "zalgebra", .module = b.dependency("zalgebra", .{}).module("zalgebra") },
                .{ .name = "nuklear", .module = nuklear_mod },
            },
        }),
    });
    b.installArtifact(exe);
    exe.addCSourceFile(.{
        .language = .c,
        .file = b.dependency("nuklear", .{}).path("nuklear.h"),
        .flags = &.{
            "-DNK_IMPLEMENTATION=1",
            "-DNK_INCLUDE_FIXED_TYPES=1",
            "-DNK_INCLUDE_DEFAULT_FONT=1",
            "-DNK_INCLUDE_FONT_BAKING=1",
            "-DNK_INCLUDE_VERTEX_BUFFER_OUTPUT=",
        },
    });
    {
        exe.addCSourceFile(.{
            .language = .c,
            .file = b.dependency("stb", .{}).path("stb_image.h"),
            .flags = &.{
                "-DSTB_IMAGE_IMPLEMENTATION=1",
                "-DSTBI_NO_STDIO=1",
            },
        });
    }

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

fn addCHeaderOnlyLib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dependency: *std.Build.Dependency,
    lib_name: []const u8,
    header_file_path: []const u8,
    common_macros: []const []const u8,
    impl_flags: []const []const u8,
) void {
    const header_path = dependency.path(header_file_path);

    const translate_c = b.addTranslateC(.{
        .root_source_file = header_path,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (common_macros) |macro| {
        translate_c.defineCMacroRaw(macro);
    }

    const c_file_path = b.allocator.alloc(u8, header_file_path.len) catch unreachable;
    _ = std.mem.replace(u8, header_file_path, ".h", ".c", c_file_path);

    const wf = b.addWriteFiles();
    const c_file = wf.addCopyFile(dependency.path(header_file_path), c_file_path);

    const flags = b.allocator.alloc([]const u8, common_macros.len + impl_flags.len) catch unreachable;
    for (common_macros, flags[0..common_macros.len]) |define, *flag| {
        flag.* = std.mem.concat(b.allocator, u8, &.{ "-D", define }) catch unreachable;
    }

    for (impl_flags, flags[common_macros.len..]) |impl_flag, *flag| {
        flag.* = impl_flag;
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = lib_name,
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .link_libc = true,
        }),
    });
    lib.addCSourceFile(.{
        .file = c_file,
        .flags = flags,
    });

    const mod = translate_c.createModule();
    mod.linkLibrary(lib);

    return mod;
}
