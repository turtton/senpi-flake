# The `omo` CLI (oh-my-openagent root bin) plus the ulw-loop component CLI,
# bundled so omo-senpi's ulw-loop and comment-checker components activate
# instead of logging "omo binary not found" / "comment-checker binary
# unavailable" and self-skipping.
#
# Runtime wiring (verified against the pinned upstream source):
#
#   senpi + omo-senpi plugin
#     └─ ulw-loop component: spawn `omo ulw-loop status --json`
#          (resolveOmoBin: $OMO_BIN, else PATH lookup for `omo`)
#        └─ $out/bin/omo  ── bun ──▶ $out/lib/omo-cli/dist/cli/index.js
#             └─ codexUlwLoop(): first candidate is
#                $CODEX_LOCAL_BIN_DIR/omo-ulw-loop; the wrapper sets
#                CODEX_LOCAL_BIN_DIR (set-default) to $out/bin so the
#                delegation always lands on the bundled component CLI
#             └─ $out/bin/omo-ulw-loop ── node ──▶ $out/lib/ulw-loop/dist/cli.js
#                  (reads .omo/ulw-loop/ ledger from the caller's cwd)
#     └─ comment-checker component: PATH lookup finds
#        $out/bin/comment-checker (symlink to the comment-checker package)
{
  lib,
  stdenvNoCC,
  callPackage,
  bun,
  nodejs_24,
  makeWrapper,
  comment-checker,
}:

let
  # Same checkout + bun dependency tree as the plugin build.  Sharing through
  # omo-common.nix keeps the fixed-output bunDeps store path identical, so
  # building both packages never duplicates the dependency install.
  common = callPackage ./omo-common.nix { };
  inherit (common) version src bunDeps;
in
stdenvNoCC.mkDerivation {
  pname = "omo-cli";
  inherit version src;

  nativeBuildInputs = [
    bun
    nodejs_24
    makeWrapper
  ];

  configurePhase = ''
    runHook preConfigure

    # Same layout requirement as the plugin build: node_modules must sit next
    # to the checkout so the relative @oh-my-opencode/* symlinks inside it
    # resolve into ./packages/*.  A symlink to the FOD is NOT sufficient — the
    # links would then resolve inside the FOD, where packages/* has no
    # package.json, and `bun build` fails with "Could not resolve:
    # @oh-my-opencode/utils/migration/model-versions".
    cp -R ${bunDeps}/node_modules ./node_modules
    chmod -R u+w ./node_modules

    for wsModules in ${bunDeps}/packages/*/node_modules; do
      [ -d "$wsModules" ] || continue
      target=packages/$(basename "$(dirname "$wsModules")")/node_modules
      cp -R "$wsModules" "$target"
      chmod -R u+w "$target"
    done

    # No patchShebangs here: unlike the plugin build (which runs tsc from
    # node_modules/.bin), both build steps below invoke bun directly.
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Mirrors the "cli" node of upstream script/build.ts (deps: [] — the bundle
    # inlines every workspace import, so no other build step must run first).
    # --target bun: the bundle needs bun at runtime, exactly like upstream's
    # own platform launchers.
    bun build packages/omo-opencode/src/cli/index.ts \
      --outdir dist/cli \
      --target bun \
      --format esm

    # The ulw-loop component (@code-yeongyu/codex-ulw-loop) is pure TypeScript
    # with zero runtime dependencies and no lockfile of its own, so `bun build`
    # (not tsc) is the only sandbox-compatible way to compile it.  It runs
    # under plain node (engines: >=20), hence --target node.
    mkdir -p ulw-loop-stage/dist
    bun build packages/omo-codex/plugin/components/ulw-loop/src/cli.ts \
      --target node \
      --outfile ulw-loop-stage/dist/cli.js

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/omo-cli/dist/cli $out/lib/ulw-loop/dist $out/bin

    cp dist/cli/index.js $out/lib/omo-cli/dist/cli/index.js

    # The component bundle resolves directive.md as ../directive.md relative
    # to itself (upstream ships dist/cli.js + directive.md in one package), so
    # the dist/ + directive.md layout must be preserved exactly.
    cp ulw-loop-stage/dist/cli.js $out/lib/ulw-loop/dist/cli.js
    cp packages/omo-codex/plugin/components/ulw-loop/directive.md \
      $out/lib/ulw-loop/directive.md

    # --set-default (not --set): a user's own CODEX_LOCAL_BIN_DIR (e.g. from a
    # codex-side install) still wins, while a bare profile install gets a
    # deterministic delegation target.
    makeWrapper ${lib.getExe bun} $out/bin/omo \
      --add-flags "$out/lib/omo-cli/dist/cli/index.js" \
      --set-default CODEX_LOCAL_BIN_DIR "$out/bin"

    makeWrapper ${lib.getExe nodejs_24} $out/bin/omo-ulw-loop \
      --add-flags "$out/lib/ulw-loop/dist/cli.js"

    # Symlink (not copy) so the binary stays a single store path shared with
    # the comment-checker package itself.
    ln -s ${comment-checker}/bin/comment-checker $out/bin/comment-checker

    # Guard against upstream build-chain drift: every path the wrappers and
    # the component layouts above depend on.
    for artifact in \
      lib/omo-cli/dist/cli/index.js \
      lib/ulw-loop/dist/cli.js \
      lib/ulw-loop/directive.md \
      bin/omo \
      bin/omo-ulw-loop \
      bin/comment-checker
    do
      if [ ! -e "$out/$artifact" ]; then
        echo "ERROR: expected build artifact missing: $artifact" >&2
        exit 1
      fi
    done

    runHook postInstall
  '';

  meta = {
    description = "omo CLI (oh-my-openagent) bundled for omo-senpi — `omo`, the `omo-ulw-loop` component CLI, and `comment-checker`";
    longDescription = ''
      Builds the oh-my-openagent CLI bundle (packages/omo-opencode/src/cli) and
      the ulw-loop component CLI (packages/omo-codex/plugin/components/ulw-loop)
      from the same monorepo pin as the omo-senpi plugin, and symlinks the
      comment-checker binary in.

      Installing this package puts `omo`, `omo-ulw-loop`, and `comment-checker`
      on PATH, which is how the omo-senpi plugin discovers them (see
      resolveOmoBin / resolveSenpiCommentCheckerBinary upstream).  The `omo`
      wrapper also sets CODEX_LOCAL_BIN_DIR (unless already set) so
      `omo ulw-loop ...` delegates to the bundled component CLI.

      In this flake the CLI exists to support omo-senpi (ulw-loop status and
      comment checking).  Other subcommands (install/run/doctor) target
      opencode/codex hosts and are not the supported use here.
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
    mainProgram = "omo";
  };
}
