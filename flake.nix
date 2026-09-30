{
  description = "Nix flake for senpi (a sane pi-mono fork by code-yeongyu)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          senpi = pkgs.callPackage ./package.nix { };
          # OmO Native is the published omo-ai package: launcher, pinned senpi
          # engine, and complete plugin payload in one store path.
          comment-checker = pkgs.callPackage ./comment-checker.nix { };
          omo-native = pkgs.callPackage ./omo-native.nix { inherit comment-checker; };
          # Compatibility outputs for existing flake consumers.
          omo-cli = omo-native;
          omo-senpi = pkgs.runCommand "omo-senpi-plugin" { } ''
            mkdir -p $out/lib
            ln -s ${omo-native}/lib/node_modules/omo-ai/plugin $out/lib/omo-senpi
          '';
          default = omo-native;
        }
      );

      overlays.default = final: _prev: {
        senpi = final.callPackage ./package.nix { };
        comment-checker = final.callPackage ./comment-checker.nix { };
        omo-native = final.callPackage ./omo-native.nix { };
        omo-cli = final.omo-native;
        omo-senpi = final.runCommand "omo-senpi-plugin" { } ''
          mkdir -p $out/lib
          ln -s ${final.omo-native}/lib/node_modules/omo-ai/plugin $out/lib/omo-senpi
        '';
      };

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
        senpi = self.packages.${system}.senpi;
        omo-native = self.packages.${system}.omo-native;
        omo-senpi = self.packages.${system}.omo-senpi;
        comment-checker = self.packages.${system}.comment-checker;
      });
    };
}
