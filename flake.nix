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
          # Senpi edition of oh-my-openagent (task/team subagents, LSP tools,
          # skills).  Unfree: Sustainable Use License, non-commercial only.
          omo-senpi = pkgs.callPackage ./omo-senpi.nix { };
          # Prebuilt tree-sitter binary the omo-senpi comment-checker
          # component shells out to.  MIT, free of unfree concerns.
          comment-checker = pkgs.callPackage ./comment-checker.nix { };
          # omo CLI + ulw-loop component CLI + comment-checker on PATH, so the
          # plugin's ulw-loop/comment-checker components activate.  Same
          # upstream pin as omo-senpi via omo-common.nix; same unfree license.
          omo-cli = pkgs.callPackage ./omo-cli.nix { inherit comment-checker; };
          default = senpi;
        }
      );

      overlays.default = final: _prev: {
        senpi = final.callPackage ./package.nix { };
        omo-senpi = final.callPackage ./omo-senpi.nix { };
        comment-checker = final.callPackage ./comment-checker.nix { };
        # callPackage fills comment-checker from final here, keeping the
        # overlay self-consistent when composed with other overlays.
        omo-cli = final.callPackage ./omo-cli.nix { };
      };

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
        omo-senpi = self.packages.${system}.omo-senpi;
        omo-cli = self.packages.${system}.omo-cli;
        comment-checker = self.packages.${system}.comment-checker;
      });
    };
}
