# Shared inputs for the omo-senpi plugin (omo-senpi.nix) and the omo CLI
# (omo-cli.nix).  Both build from the same oh-my-openagent checkout and the
# same bun dependency tree; factoring them out here keeps the plugin and the
# CLI on the same upstream pin by construction, and lets Nix realise the
# dependency tree exactly once even when both packages are built together.
{
  lib,
  stdenvNoCC,
  fetchgit,
  fetchurl,
  writeText,
  nodejs_24,
}:

let
  hashesData = lib.importJSON ./omo-hashes.json;
  version = hashesData.version;

  src = fetchgit {
    url = "https://github.com/code-yeongyu/oh-my-openagent";
    rev = hashesData.rev;
    hash = hashesData.srcHash;
    # packages/shared-skills/upstreams/* are git submodules; the frontend skill
    # references are materialized from them at build time.
    fetchSubmodules = true;
  };

  # npm dependency data generated from bun.lock by generate-npm-packages.py
  # (update-omo.sh regenerates it on every rev bump).  The generator runs
  # without os/cpu filtering, so one JSON serves every supported system.
  npmPkgsData = lib.importJSON ./omo-npm-packages.json;

  # Every npm tarball as an individual fixed-output fetchurl, keyed exactly
  # like npmPackages so the build-time assembler can find its store path.
  # Hashes come straight from bun.lock's integrity fields: the dependency
  # tree needs no hash-discovery build and cannot flip between runs.  This
  # replaces the previous single-output `bun install` FOD, whose output hash
  # proved unstable in CI even with --backend=copyfile and cache isolation.
  fetchedPkgs = lib.mapAttrs (_: info: fetchurl { inherit (info) url hash; }) npmPkgsData.npmPackages;

  # Maps package key -> tarball store path for the assembler.
  pkgMappingFile = writeText "omo-npm-pkg-mapping.json" (
    builtins.toJSON (lib.mapAttrs (_: pkg: "${pkg}") fetchedPkgs)
  );

  # Assemble node_modules from the fetched tarballs.  The layout mirrors
  # `bun install`: root node_modules plus per-workspace node_modules
  # (bun.lock's key structure encodes the install location), workspace:* and
  # file: deps as relative symlinks into ./packages/* (they dangle until the
  # tree is copied next to the checkout — same contract as the old FOD), and
  # node_modules/.bin entry points for packages that ship bins.
  bunDeps = stdenvNoCC.mkDerivation {
    pname = "omo-senpi-bun-deps";
    inherit version;

    nativeBuildInputs = [ nodejs_24 ];

    # No src: the tree is assembled from the individually fetched tarballs.
    dontConfigure = true;
    dontUnpack = true;

    buildPhase = ''
      runHook preBuild

      node ${./assemble-node-modules.cjs} ${./omo-npm-packages.json} ${pkgMappingFile}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R node_modules $out/

      for wsModules in packages/*/node_modules; do
        [ -d "$wsModules" ] || continue
        mkdir -p "$out/$(dirname "$wsModules")"
        cp -R "$wsModules" "$out/$wsModules"
      done

      runHook postInstall
    '';

    # Tarballs ship prebuilt binaries (native addons); leave the tree
    # byte-identical to upstream.  Shebangs are fixed by the consumers after
    # the tree is copied next to the checkout.
    dontFixup = true;
    dontPatchShebangs = true;

    # node_modules/@oh-my-opencode/* are relative symlinks into ../packages/*,
    # which only resolve once the tree is copied back next to the checkout in
    # configurePhase.  Inside this derivation they are expected to dangle.
    dontCheckForBrokenSymlinks = true;
  };
in
{
  inherit
    hashesData
    version
    src
    bunDeps
    ;
}
