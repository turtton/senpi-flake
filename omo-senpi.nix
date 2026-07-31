{
  lib,
  stdenvNoCC,
  callPackage,
  fetchNpmDeps,
  bun,
  nodejs_24,
  npmHooks,
  git,
}:

let
  # Upstream checkout + bun dependency tree, shared with omo-cli.nix so the
  # plugin and the CLI always build from the same pin.  See omo-common.nix.
  common = callPackage ./omo-common.nix { };
  inherit (common) hashesData version src bunDeps;

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
