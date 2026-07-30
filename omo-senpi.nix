{
  lib,
  stdenvNoCC,
  fetchgit,
  fetchNpmDeps,
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

      bun install \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress

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

      runHook postInstall
    '';

    # bun stores absolute paths in binary lockfiles and hardlinks into its
    # cache; strip the generated lockfile so the output only contains the tree.
    postFixup = ''
      rm -f $out/node_modules/.bun-tag* $out/bun.lock
    '';

    dontPatchShebangs = true;

    # node_modules/@oh-my-opencode/* are relative symlinks into ../packages/*,
    # which only resolve once the tree is copied back next to the checkout in
    # configurePhase.  Inside this FOD they are expected to dangle.
    dontCheckForBrokenSymlinks = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = hashesData.bunDepsHash;

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  };

  # packages/lsp-daemon carries its own npm lockfile (`npm ci` in the upstream
  # build script), independent of the bun workspace.
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

  # npmConfigHook operates on packages/lsp-daemon's lockfile, not the repo root.
  npmDeps = lspDaemonNpmDeps;
  npmRoot = "packages/lsp-daemon";

  postPatch = ''
    # materialize-shared-upstreams.mjs runs `git submodule update --init`, which
    # cannot work inside the sandbox (no .git, no network).  fetchSubmodules
    # already placed the upstream trees, so drop --strict to take the script's
    # documented "continuing without submodule refresh" path.
    substituteInPlace package.json \
      --replace-fail \
        'node packages/omo-codex/plugin/scripts/materialize-shared-upstreams.mjs --strict' \
        'node packages/omo-codex/plugin/scripts/materialize-shared-upstreams.mjs'

    # The upstream build runs `npm ci` itself; npmConfigHook has already
    # populated packages/lsp-daemon/node_modules from the pinned lockfile.
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

    # The deps FOD keeps upstream shebangs (`#!/usr/bin/env node`) so its hash
    # does not depend on store paths; fix them up now that the tree is local,
    # otherwise `node_modules/.bin/tsc` fails with "bad interpreter".
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

  # Senpi loads local-path packages straight from the given directory without
  # copying, so the plugin tree can live read-only in the store.  Verified:
  # extensions/omo.js loads from a read-only path and registers the task/team
  # tools, and a child agent runs to completion.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/omo-senpi
    cp -R packages/omo-senpi/plugin/. $out/lib/omo-senpi/

    # Guard against upstream build-chain drift: these are the artifacts
    # scripts/install.mjs validates before registering the package.
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

  # skills/ ships portable helper scripts (e.g. skills/ast-grep/install.sh) that
  # the agent runs on the user's machine; rewriting their `#!/usr/bin/env bash`
  # to a nix bash would pin them to this closure.  Nothing in the plugin is
  # executed as a nix-provided entrypoint, so no shebang needs patching.
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
    # Sustainable Use License: free to use and to distribute at no charge for
    # non-commercial purposes only.  Not an OSI-approved license.
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
