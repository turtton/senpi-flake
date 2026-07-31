{
  lib,
  stdenvNoCC,
  fetchgit,
  fetchurl,
  fetchNpmDeps,
  writeText,
  bun,
  nodejs_24,
  npmHooks,
  cacert,
  git,
}:

let
  hashesData = lib.importJSON ./omo-hashes.json;
  version = hashesData.version;

  src = fetchgit {
    url = "https://github.com/code-yeongyu/oh-my-openagent";
    rev = hashesData.rev;
    hash = hashesData.srcHash;
    fetchSubmodules = true;
  };

  # ----------------------------------------------------------------
  # npm package data — generated from bun.lock via generate-npm-packages.py
  # Structure: { "pkg-key": { "url": "...", "hash": "sha512-..." }, ... }
  # ----------------------------------------------------------------
  npmPkgsData = builtins.fromJSON (builtins.readFile ./omo-npm-packages.json);

  # ----------------------------------------------------------------
  # Fetch every npm tarball with individual fetchurl calls.
  # Each value is a store path to the downloaded .tgz.
  # ----------------------------------------------------------------
  fetchedPkgs = lib.mapAttrs (_: info: fetchurl {
    url = info.url;
    hash = info.hash;
  }) npmPkgsData;

  # ----------------------------------------------------------------
  # Create a JSON mapping file: { "pkg-key": "/nix/store/...-name", ... }
  # The builder reads this at build time to know where each tarball is.
  # ----------------------------------------------------------------
  pkgMappingFile = writeText "npm-pkg-mapping.json" (builtins.toJSON (
    lib.mapAttrs (_: pkg: "${pkg}") fetchedPkgs
  ));

  # ----------------------------------------------------------------
  # Root package.json + bun.lock + every workspace manifest.
  # Kept for bunManifests-based workspace handling.
  # ----------------------------------------------------------------
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

  # ----------------------------------------------------------------
  # Build node_modules from individual fetchurl tarballs.
  # Reads omo-npm-packages.json and the pkg-mapping.json at build time.
  # ----------------------------------------------------------------
  bunDeps = stdenvNoCC.mkDerivation {
    pname = "omo-senpi-bun-deps";
    inherit version;

    nativeBuildInputs = [ nodejs_24 ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      # Read the npm packages data and the fetchurl mapping
      PKG_DATA=${./omo-npm-packages.json}
      PKG_MAP=${pkgMappingFile}

      # Node script that assembles node_modules from individual tarballs
      node -e "
        const fs = require('fs');
        const { execSync } = require('child_process');

        const pkgData = JSON.parse(fs.readFileSync('$PKG_DATA', 'utf8'));
        const pkgMap = JSON.parse(fs.readFileSync('$PKG_MAP', 'utf8'));

        const npmPkgs = pkgData.npmPackages || {};
        const wsSymlinks = pkgData.workspaceSymlinks || {};
        const filePkgs = pkgData.filePackages || {};

        let unpacked = 0;
        let symlinked = 0;

        // ── Unpack each npm tarball into its node_modules path ──
        for (const [key, info] of Object.entries(npmPkgs)) {
          const storePath = pkgMap[key];
          if (!storePath) {
            console.error('WARNING: no mapping for ' + key);
            continue;
          }

          const installPath = info.installPath;
          fs.mkdirSync(installPath, { recursive: true });

          // npm tarballs have a 'package/' prefix; strip it
          execSync('tar xzf ' + JSON.stringify(storePath) +
                   ' --strip-components=1 -C ' + JSON.stringify(installPath),
                   { stdio: 'inherit' });
          unpacked++;
        }

        // ── Create workspace symlinks ────────────────────────────
        // workspace: deps → symlink to source tree
        for (const [key, info] of Object.entries(wsSymlinks)) {
          const installPath = info.installPath;
          const sourcePath = info.sourcePath;

          fs.mkdirSync(installPath, { recursive: true, recursive: true });

          // Calculate relative path from installPath to sourcePath
          const installDir = require('path').dirname(installPath);
          const relPath = require('path').relative(installDir, sourcePath);

          try { fs.unlinkSync(installPath); } catch {}
          fs.symlinkSync(relPath, installPath);
          symlinked++;
        }

        // ── Create file: symlinks ────────────────────────────────
        // file: deps → symlink to source tree
        for (const [key, info] of Object.entries(filePkgs)) {
          const installPath = info.installPath;
          const sourcePath = info.sourcePath;

          fs.mkdirSync(installPath, { recursive: true });

          const installDir = require('path').dirname(installPath);
          const relPath = require('path').relative(installDir, sourcePath);

          try { fs.unlinkSync(installPath); } catch {}
          fs.symlinkSync(relPath, installPath);
          symlinked++;
        }

        console.log('Unpacked ' + unpacked + ' npm packages, created ' + symlinked + ' symlinks');
      "

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R node_modules $out/

      # Also copy workspace-level node_modules (bun creates these in workspaces)
      for wsModules in packages/*/node_modules; do
        [ -d "$wsModules" ] || continue
        mkdir -p "$out/$(dirname "$wsModules")"
        cp -R "$wsModules" "$out/$wsModules"
      done

      runHook postInstall
    '';

    # bun stores absolute paths in binary lockfiles; strip generated artifacts
    postFixup = ''
      rm -f $out/node_modules/.bun-tag* $out/bun.lock
    '';

    dontPatchShebangs = true;
    # node_modules/@oh-my-opencode/* are relative symlinks into ../packages/*
    dontCheckForBrokenSymlinks = true;
  };

  # packages/lsp-daemon npm deps (its own lockfile)
  lspDaemonNpmDeps = fetchNpmDeps {
    name = "omo-senpi-lsp-daemon-npm-deps";
    src = "${src}/packages/lsp-daemon";
    hash = hashesData.lspDaemonNpmDepsHash;
  };
in
stdenvNoCC.mkDerivation {
  pname = "omo-senpi";
  inherit version src;

  nativeBuildInputs = [
    bun
    nodejs_24
    npmHooks.npmConfigHook
    git
  ];

  # npmConfigHook operates on packages/lsp-daemon's lockfile
  npmDeps = lspDaemonNpmDeps;
  npmRoot = "packages/lsp-daemon";

  postPatch = ''
    # materialize-shared-upstreams.mjs runs `git submodule update --init`,
    # impossible inside the sandbox
    substituteInPlace package.json \
      --replace-fail \
        'node packages/omo-codex/plugin/scripts/materialize-shared-upstreams.mjs --strict' \
        'node packages/omo-codex/plugin/scripts/materialize-shared-upstreams.mjs'

    # npmConfigHook already populated packages/lsp-daemon/node_modules
    substituteInPlace package.json \
      --replace-fail \
        'npm --prefix packages/lsp-daemon ci && npm --prefix packages/lsp-daemon run build' \
        'npm --prefix packages/lsp-daemon run build'
  '';

  configurePhase = ''
    runHook preConfigure

    cp -R ${bunDeps}/node_modules ./node_modules
    chmod -R u+w ./node_modules

    for wsModules in ${bunDeps}/packages/*/node_modules; do
      [ -d "$wsModules" ] || continue
      target=packages/$(basename "$(dirname "$wsModules")")/node_modules
      cp -R "$wsModules" "$target"
      chmod -R u+w "$target"
    done

    # Fix shebangs that the deps FOD kept upstream
    patchShebangs ./node_modules/.bin
    for pkgBin in ./node_modules/*/bin ./node_modules/@*/*/bin; do
      [ -d "$pkgBin" ] && patchShebangs "$pkgBin"
    done

    export HOME=$TMPDIR/home
    mkdir -p "$HOME"

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    bun run build:senpi-plugin

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/omo-senpi
    cp -R packages/omo-senpi/plugin/. $out/lib/omo-senpi/

    # Guard against upstream build-chain drift
    for artifact in \
      extensions/omo.js \
      skills/ast-grep/SKILL.md \
      runtime/lsp-daemon/dist/cli.js \
      runtime/lsp-daemon/dist/.omo-runtime-manifest.json
    do
      if [ ! -f "$out/lib/omo-senpi/$artifact" ]; then
        echo "ERROR: expected build artifact missing: $artifact" >&2
        exit 1
      fi
    done

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchShebangs = true;

  passthru.pluginPath = "/lib/omo-senpi";

  meta = {
    description = "Senpi edition of oh-my-openagent (omo) — task/team subagents, LSP tools, and skills as a senpi package";
    longDescription = ''
      Builds packages/omo-senpi/plugin from the oh-my-openagent monorepo, the
      successor to the archived pi-task extension.  Register it with senpi by
      adding the store path to the `packages` array in
      ~/.senpi/agent/settings.json, or run:

        senpi install "$(nix build --no-link --print-out-paths .#omo-senpi)/lib/omo-senpi"
    '';
    homepage = "https://github.com/code-yeongyu/oh-my-openagent";
    license = {
      shortName = "sustainable-use-1.0";
      fullName = "Sustainable Use License v1.0";
      url = "https://github.com/code-yeongyu/oh-my-openagent/blob/main/LICENSE.md";
      free = false;
      redistributable = false;
    };
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}
