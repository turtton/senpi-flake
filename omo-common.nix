# Shared inputs for the omo-senpi plugin (omo-senpi.nix) and the omo CLI
# (omo-cli.nix).  Both build from the same oh-my-openagent checkout and the
# same bun dependency tree; factoring them out here keeps the plugin and the
# CLI on the same upstream pin by construction, and lets Nix realise the
# fixed-output bunDeps derivation exactly once even when both packages are
# built together.
#
# WARNING: every attribute that feeds bunDeps (pname, version, src, phases,
# env, outputHash) determines its derivation hash.  Changing anything here
# invalidates the pinned bunDepsHash in omo-hashes.json for ALL consumers at
# once — run update-omo.sh afterwards to rediscover it.
{
  lib,
  stdenvNoCC,
  fetchgit,
  bun,
  nodejs_24,
  cacert,
  system,
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

  # Root package.json + bun.lock + every package.json referenced by the bun
  # workspace.  Bun only needs the manifests to resolve the dependency tree, so
  # the FOD input stays tiny and only changes when a manifest or the lockfile
  # changes.
  #
  # packages/lsp-daemon is NOT in the root `workspaces` array but is pulled in
  # through `"@code-yeongyu/lsp-daemon": "file:../lsp-daemon"` from
  # packages/omo-senpi; omitting its manifest makes `bun install` fail with
  # ENOENT while linking.
  bunManifests = stdenvNoCC.mkDerivation {
    pname = "omo-senpi-bun-manifests";
    inherit version src;

    nativeBuildInputs = [ nodejs_24 ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp package.json bun.lock $out/

      workspaces=$(node -p 'require("./package.json").workspaces.join("\n")')
      for ws in $workspaces packages/lsp-daemon; do
        if [ -f "$ws/package.json" ]; then
          mkdir -p "$out/$ws"
          cp "$ws/package.json" "$out/$ws/package.json"
        fi
      done

      runHook postInstall
    '';
  };

  # `bun install` output is byte-identical across runs (verified with
  # `diff -r` over two installs with independent HOMEs), so a fixed-output
  # derivation is safe here.  nixpkgs has no bun lockfile fetcher, hence the FOD.
  bunDeps = stdenvNoCC.mkDerivation {
    pname = "omo-senpi-bun-deps";
    inherit version;

    src = bunManifests;

    nativeBuildInputs = [ bun ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$TMPDIR/home
      mkdir -p "$HOME"

      # Isolate bun's global cache completely to make install output
      # deterministic across builds.  bun's default --backend=hardlink
      # references inodes from the cache, and the cache state (hit/miss)
      # varies between sandbox sessions, causing the FOD hash to flip
      # between two values.  --backend=copyfile and an isolated cache dir
      # eliminate this source of non-determinism.
      export BUN_INSTALL_CACHE_DIR=$TMPDIR/bun-cache
      mkdir -p "$BUN_INSTALL_CACHE_DIR"

      bun install \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress \
        --backend=copyfile

      runHook postBuild
    '';

    # bun creates a node_modules/ inside every workspace package too (24 of
    # them), and some links only exist there -- e.g.
    # packages/omo-senpi/node_modules/@oh-my-opencode/omo-opencode.  Keeping
    # only the root tree makes `bun build` fail to resolve
    # "@oh-my-opencode/omo-opencode/config-migration".
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R node_modules $out/

      for wsModules in packages/*/node_modules; do
        [ -d "$wsModules" ] || continue
        mkdir -p "$out/$(dirname "$wsModules")"
        cp -R "$wsModules" "$out/$wsModules"
      done

      # Remove non-deterministic bun temp/artifact files recursively
      find $out -name '.bun-tag*' -delete 2>/dev/null || true
      find $out -name 'bun.lock' -delete 2>/dev/null || true

      runHook postInstall
    '';

    # Skip fixup phase (patchelf / strip) to avoid ELF-binary
    # transformations.  The node_modules tree is consumed as-is.
    dontFixup = true;
    dontPatchShebangs = true;

    # node_modules/@oh-my-opencode/* are relative symlinks into ../packages/*,
    # which only resolve once the tree is copied back next to the checkout in
    # configurePhase.  Inside this FOD they are expected to dangle.
    dontCheckForBrokenSymlinks = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = hashesData.bunDepsHash.${system} or (throw "omo-senpi: no bunDepsHash for system \"${system}\"");

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  };
in
{
  inherit
    hashesData
    version
    src
    bunManifests
    bunDeps
    ;
}
