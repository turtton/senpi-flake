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
        {
          senpi = pkgs.callPackage ./package.nix { };
          # Senpi edition of oh-my-openagent (task/team subagents, LSP tools,
          # skills).  Unfree: Sustainable Use License, non-commercial only.
          omo-senpi = pkgs.callPackage ./omo-senpi.nix { };
          default = self.packages.${system}.senpi;
        }
      );

      overlays.default = final: _prev: {
        senpi = final.callPackage ./package.nix { };
        omo-senpi = final.callPackage ./omo-senpi.nix { };
      };

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
        omo-senpi = self.packages.${system}.omo-senpi;
      });
    };
}
