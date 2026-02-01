# Vulkan Path Tracer

## Build and run

```
zig build run -Doptimize=ReleaseSafe -- --scene-path PATH_TO_SCENE
```

### Dependencies
* zig version `0.15.2` [Linux](https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz) [Windows](https://ziglang.org/download/0.15.2/zig-windows-x86_64-0.15.2.zip)

## glTF scene compatability
glTF scenes require vetex UVs, normals and tangets along with materials for all meshes.

The [glTF sample assets](https://github.com/KhronosGroup/glTF-Sample-Assets) can be used to test the path tracer but some might need to have tangents added to them.

## Command line arguments
* `--scene-path` sets the path to the glTF scene to be rendered, no default this argument is required.
* `--num-samples` sets the number of samples which are taken every frame, default is 1.
* `--num-bounces` sets the number of bounces a ray can make before being terminated, default is 2.
