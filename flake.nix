{
  description = "Zig Vulkan Pathtracer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    zls,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        zigpkg = zig-overlay.packages.${system}.master;
        zlspkg = zls.packages.${system}.zls;
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
              zigpkg
              zlspkg
              shaderc
              glfw
              vulkan-loader
              vulkan-validation-layers
              xorg.libxcb
              xcb-util-cursor
              glsl_analyzer
          ];

          hardeningDisable = ["all"];
          LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [pkgs.vulkan-loader]}";
          VK_LAYER_PATH="${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
        };

        devShell = self.devShells.${system}.default;
      }
    );
}
