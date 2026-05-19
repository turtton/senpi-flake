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
          default = self.packages.${system}.senpi;
        }
      );

      overlays.default = final: _prev: {
        senpi = final.callPackage ./package.nix { };
      };
    };
}
