{
  description = "Zig Vulkan Pathtracer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls/0.15.0";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig-overlay";
      };
    };
  };


  outputs = inputs:
    let
      supportedSystems = [ "x86_64-linux" ];
      forEachSupportedSystem = f: inputs.nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = import inputs.nixpkgs { inherit system; };
        zigpkg = inputs.zig-overlay.packages.${system}."0.15.1";
        zlspkg = inputs.zls.packages.${system}.zls;
      });
    in
    {
      devShells = forEachSupportedSystem ({ pkgs, zigpkg, zlspkg }: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zigpkg
            zlspkg
            vulkan-loader
            vulkan-validation-layers
            xorg.libxcb
            glsl_analyzer
            gdbgui
            wayland
          ];

          hardeningDisable = [ "all" ];

          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [
            pkgs.vulkan-loader
            pkgs.xorg.libxcb
            pkgs.wayland
          ]}";
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };
      });
    };
}
