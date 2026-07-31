# senpi-flake — AGENTS.md

Nix flake for [@code-yeongyu/senpi](https://github.com/code-yeongyu/senpi), an npm-published coding agent CLI with bundled native dependencies.

## Repo structure

| File | Purpose |
|---|---|
| `flake.nix` | Flake entrypoint — calls `package.nix` / `omo-senpi.nix` / `omo-cli.nix` / `comment-checker.nix` per system, exposes an overlay + checks |
| `package.nix` | senpi derivation — fetches npm tarball + GitHub source, handles bundled deps, wraps binary |
| `hashes.json` | senpi version + SRI hashes (sourceHash, assetsSourceHash, npmDepsHash) + bundledDependencies list |
| `package-lock.json` | Committed lockfile for reproducible npm dependency resolution |
| `update.sh` | senpi: NPM registry → tarball → npmDepsHash discovery workflow |
| `omo-common.nix` | Shared omo inputs — monorepo checkout + per-tarball `fetchurl` bun dependency tree, consumed by both `omo-senpi.nix` and `omo-cli.nix` |
| `omo-senpi.nix` | omo-senpi derivation — builds `packages/omo-senpi/plugin` from the oh-my-openagent monorepo |
| `omo-cli.nix` | omo CLI derivation — `omo` (bun bundle), `omo-ulw-loop` (node bundle), `comment-checker` symlink |
| `comment-checker.nix` | comment-checker derivation — per-platform prebuilt binary from upstream GitHub releases |
| `omo-hashes.json` | omo pin: rev, version, srcHash, lspDaemonNpmDepsHash + commentChecker version/per-system hashes |
| `omo-npm-packages.json` | Generated from bun.lock — per-tarball URL + integrity hash for every npm package, plus workspace/file link data |
| `generate-npm-packages.py` | bun.lock (JSONC) → `omo-npm-packages.json` generator; run by `update-omo.sh` on every rev bump |
| `assemble-node-modules.cjs` | Build-time assembler — unpacks the fetched tarballs into a bun-shaped node_modules (workspace links + `.bin`) |
| `update-omo.sh` | omo: GitHub HEAD → submodule prefetch → bun.lock regeneration → lsp-daemon hash discovery; comment-checker: npm registry → direct archive prefetch |
| `.github/workflows/ci.yml` | PR/push CI: `nix flake check`, all builds, binary + plugin-load + omo-cli delegation verification |
| `.github/workflows/update.yml` | Daily cron: `update.sh` + `update-omo.sh` → build → PR (with PAT_TOKEN fallback) |
| `AGENTS.md` | This file — maintainer documentation |

## hashes.json structure

```json
{
  "version": "2026.7.24",
  "sourceHash": "sha256-z5dxKX8A/lKXA09ydSuMcA1yQbqmFNLPROGKnqBxBWI=",
  "assetsSourceHash": "sha256-65BFJjwH24Q2TxwlAgw8vjTnYYbEVU04qZ3lIeXDWCI=",
  "npmDepsHash": "sha256-L+ua1aNYL7C7Zp7GrBIsqY1WrpL2sxQSeIO3yTeH0Hw=",
  "bundledDependencies": [
    "@anthropic-ai/sdk",
    "@aws-sdk/client-bedrock-runtime",
    "@earendil-works/pi-agent-core",
    ...
  ]
}
```

### Fields

| Field | Description |
|---|---|
| `version` | The upstream npm package version (semver or date-based) |
| `sourceHash` | SRI hash of the npm registry tarball (`sha256-...` Nix format) |
| `assetsSourceHash` | SRI hash of the GitHub source tarball at the matching `v{version}` tag; contains non-JS assets (theme JSON, PNG templates, vendored JS) that the npm tarball doesn't ship |
| `npmDepsHash` | SRI hash of the npm dependency lockfile tree, discovered via `nix build` |
| `bundledDependencies` | Array of package names that the npm tarball ships in `node_modules/`; removed from `package.json` before lockfile generation and restored from `.bundled-deps/` after `npm install` |

## Key commands

```bash
# Build locally
nix build .#senpi

# Run the built binary
./result/bin/senpi --version
./result/bin/pi --version  # alias

# Run flake checks (builds all packages; the omo packages are unfree)
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure

# Update to latest upstream release (keep both in lockstep)
bash update.sh
bash update-omo.sh

# Build and install the omo-senpi plugin into senpi
NIXPKGS_ALLOW_UNFREE=1 nix build .#omo-senpi --impure
senpi install "$(realpath ./result)/lib/omo-senpi"

# Build the omo CLI bundle (omo / omo-ulw-loop / comment-checker) so the
# plugin's ulw-loop and comment-checker components activate; install it so
# its bin/ is on PATH (omo-senpi discovers the binaries via PATH lookup)
NIXPKGS_ALLOW_UNFREE=1 nix build .#omo-cli --impure
./result/bin/omo --version
./result/bin/omo ulw-loop status --json   # JSON; ULW_LOOP_PLAN_MISSING + exit 1 when idle
./result/bin/comment-checker --help       # no --version flag upstream
```

## How update.sh works (npm registry → tarball → npmDepsHash discovery)

1. **Query npm registry**: `curl https://registry.npmjs.org/@code-yeongyu/senpi/latest` → gets latest version + tarball URL
2. **Prefetch source hash**: `nix-prefetch-url --type sha256 <tarball_url>` → converts to SRI format
3. **Prefetch assets hash**: Same for the GitHub source tarball at `v{version}` tag
4. **Regenerate package-lock.json**:
   - Downloads the npm tarball
   - Strips `bundledDependencies` entries from `package.json` (their lockfile entries lack integrity hashes, which would break `buildNpmPackage`)
   - Removes `npm-shrinkwrap.json` and `node_modules/` (pre-existing directories would corrupt lockfile generation)
   - Runs `npm install --package-lock-only --ignore-scripts` in a clean directory
   - Copies the fresh `package-lock.json` into the repo
5. **Stamp placeholder hash**: Writes `npmDepsHash: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=` to `hashes.json`
6. **Discover real npmDepsHash**: Runs `nix build .#senpi --no-link` (expected to fail) and extracts `got: sha256-...` from the build log
7. **Write final hashes**: Updates `npmDepsHash` with the discovered hash, runs a verification build

## Packaging quirks

- **NPM package with bundled deps**: The npm tarball includes a `node_modules/` directory with packages from `@earendil-works/*` (which are not on the npm registry) and their transitive dependencies. The flake preserves these in `.bundled-deps/` before stripping them from `package.json`, then copies them back after `npm install`.
- **Lockfile committed**: `package-lock.json` is committed to the repo (not in `.gitignore`) so the lockfile from `update.sh` survives CI runs. The derivation injects it into the build sandbox.
- **No build step**: `dontNpmBuild = true` — the npm tarball already ships compiled `dist/`.
- **Asset injection**: `postPatch` copies theme JSON, PNG icons, and HTML templates from the GitHub source tarball into `dist/`, mirroring what upstream's `copy-assets` script does.
- **pi alias**: A `pi` symlink is created alongside `senpi` in `$out/bin` for compatibility.
- **Node.js 24**: Required at runtime; `postFixup` wraps the binary with `nodejs_24` in PATH.

## omo-senpi (subagent / task tooling)

`omo-senpi` packages `packages/omo-senpi/plugin` from [oh-my-openagent](https://github.com/code-yeongyu/oh-my-openagent). It is the successor to the archived `pi-task` extension and provides `task`, `task_send`, `task_output`, `task_cancel`, the `team_*` family, the six `lsp_*` tools, and 20 skills.

### Why it is not an npm/git package

Upstream states the install surface is local-path only: `extensions/` and `skills/` are build outputs and are not shipped. The published `oh-my-openagent` npm tarball contains **zero** `omo-senpi` paths (verified), so the plugin must be built from the git checkout.

### omo-hashes.json fields

| Field | Description |
|---|---|
| `rev` | Pinned oh-my-openagent commit |
| `version` | Monorepo root `package.json` version at that commit |
| `srcHash` | `fetchgit` hash **with submodules** (`packages/shared-skills/upstreams/*` feed the frontend skill references) |
| `lspDaemonNpmDepsHash` | `fetchNpmDeps` hash for `packages/lsp-daemon` (its own npm lockfile); the only remaining discovery FOD |
| `commentChecker.version` | comment-checker release version (independent of the monorepo pin) |
| `commentChecker.hashes` | Per-system SRI hashes of the four upstream release archives (`x86_64-linux` / `aarch64-linux` / `x86_64-darwin` / `aarch64-darwin`) |

Note: there is intentionally **no `bunDepsHash`** — bun dependency hashes live per-tarball in `omo-npm-packages.json` (see Packaging quirks), which is platform-independent, so the omo packages evaluate on all four supported systems.

### Packaging quirks

- **Shared inputs in `omo-common.nix`**: the checkout (`fetchgit`) and the bun dependency tree are factored out so `omo-senpi.nix` and `omo-cli.nix` stay on the same pin and share one realised dependency derivation.
- **bun deps as per-tarball `fetchurl`, not a FOD**: nixpkgs has no bun lockfile fetcher, and the previous single-output `bun install` FOD proved unstable in CI — its hash flipped across environments even with `--backend=copyfile` and cache isolation (observed as `discover-macos-hash` failures after merges). `generate-npm-packages.py` therefore parses bun.lock (JSONC) into `omo-npm-packages.json` — URL + lockfile integrity hash per npm package, workspace/file link data, bin entries — and `omo-common.nix` fetches each tarball individually and assembles node_modules at build time with `assemble-node-modules.cjs`. Every byte is covered by a lockfile hash, so nothing needs discovery and nothing can flip. The generator runs **without os/cpu filtering** (all platform variants are unpacked; non-matching ones are inert), which keeps the tree platform-independent.
- **Two dependency managers**: the repo is a bun workspace, but `packages/lsp-daemon` is built with `npm ci` against its own `package-lock.json`. The derivation lets `npmConfigHook` populate it (`npmRoot = "packages/lsp-daemon"`) and patches the `npm ci` out of the build script.
- **Per-workspace `node_modules`**: bun.lock's key structure encodes where each package installs (root vs a workspace's own `node_modules/`); the assembler reproduces that layout, and workspace-specific links (e.g. `packages/omo-senpi/node_modules/@code-yeongyu/lsp-daemon`) are created as relative symlinks into the checkout.
- **file: deps are links, not copies**: entries nested under a `file:` package (e.g. `typescript` keyed under `@code-yeongyu/lsp-daemon`) are skipped by the assembler — the linked source directory's own dependency manager (`packages/lsp-daemon`'s npm ci) already provides them, and unpacking them would collide with the symlink.
- **Shebangs**: tarballs keep upstream `#!/usr/bin/env node` shebangs; `configurePhase` runs `patchShebangs` after copying the tree next to the checkout, otherwise `node_modules/.bin/tsc` fails with `bad interpreter`.
- **Dangling symlinks in the deps derivation**: `node_modules/@oh-my-opencode/*` are relative links into `../packages/*` and only resolve once copied next to the checkout, so `dontCheckForBrokenSymlinks = true`.
- **Submodule script**: `materialize-shared-upstreams.mjs --strict` runs `git submodule update --init`, impossible in the sandbox. `fetchSubmodules` already supplies the trees, so `postPatch` drops `--strict` to take the script's documented "continuing without submodule refresh" path.
- **Unfree**: Sustainable Use License (non-commercial, free-of-charge distribution only). Every `nix` invocation needs `NIXPKGS_ALLOW_UNFREE=1` and `--impure`.
- **Shebangs in `skills/`**: top-level `dontPatchShebangs = true`. `skills/` ships portable helper scripts (`skills/ast-grep/install.sh`, the `programming` scripts) that the agent runs on the user's machine, so their `#!/usr/bin/env bash` must survive. The `patchShebangs` call inside `configurePhase` is explicit and still runs.
- **Reproducible since rev `bc92958`**: the extension bundle used to be non-deterministic (`bun build --minify` picked different mangled identifier names between runs, flipping the body digest in omo's own `// omo-senpi-build:<sourceDigest>:<bodyDigest>` marker). Current upstream builds bit-reproducibly — verified with two consecutive `nix build .#omo-senpi --rebuild` passes (and one for `.#omo-cli`) at rev `bc92958`. If a future update reintroduces a mismatch, treat it as an upstream regression, not a packaging defect.

### Runtime facts (verified, not assumed)

- senpi loads local-path packages without copying, so the plugin runs from the read-only store path. Verified: `senpi list` reports the store path, the extension initializes, and `task`/`team_*`/`lsp_*` all register.
- A child agent spawned through `task` runs to completion from the store path.
- All mutable state goes to `$HOME/.omo/` (`lsp-daemon/v0.1.0/daemon.{sock,pid,log,auth}`, `codegraph/`). Nothing is written into the store path.
- Build artifacts contain no build-machine absolute paths.
- With `omo-cli`'s `bin/` on PATH, the ulw-loop component activates and polls `omo ulw-loop status --json` on session events; in a directory without a plan this logs `omo-senpi ulw-loop status ignored { reason: 'non-zero-exit', code: 1 }` (the bundled CLI answers `ULW_LOOP_PLAN_MISSING` with exit 1), which is the component working as designed, not skipping. Without `omo-cli`, startup logs `omo binary not found` and the component self-skips. The comment-checker component resolves its binary lazily (first edit/write), so `comment-checker binary unavailable` appears at that point if `comment-checker` is not on PATH. The task/team and LSP components require neither binary.

### Version coupling

`packages/senpi-task` pins its senpi peer exactly (e.g. `@code-yeongyu/senpi: 2026.7.26`). The extension bundle externalizes the senpi peer family and resolves it from the host at runtime, so a drifting senpi can make components self-skip rather than crash — the task tool would silently disappear. Hence `update.yml` runs `update.sh` and `update-omo.sh` in the same job so both move together.

## omo-cli (omo / omo-ulw-loop / comment-checker on PATH)

`omo-cli` bundles the binaries omo-senpi's ulw-loop and comment-checker components look up on PATH, from the same monorepo pin as the plugin:

- **`omo`** — `bun build packages/omo-opencode/src/cli/index.ts --target bun` (mirrors the `cli` node of upstream `script/build.ts`, which has no deps because the bundle inlines every workspace import). Runs under **bun** at runtime via a `makeWrapper` around `${bun}/bin/bun`.
- **`omo-ulw-loop`** — the ulw-loop component CLI (`packages/omo-codex/plugin/components/ulw-loop`), a zero-dependency TypeScript package with no lockfile, so `bun build --target node` is the only sandbox-compatible build. Runs under **nodejs_24** at runtime.
- **`comment-checker`** — symlink to the `comment-checker` package below.

### Runtime wiring (verified against the pinned source)

1. The ulw-loop component resolves `omo` via `$OMO_BIN`, then PATH (`resolveOmoBin`), and spawns `omo ulw-loop status --json` on session events.
2. The omo CLI's `ulw-loop` subcommand delegates (`codexUlwLoop`): the first candidate is `$CODEX_LOCAL_BIN_DIR/omo-ulw-loop`, then `~/.local/bin`, then `~/.codex/bin`, then the codex plugin cache. The `omo` wrapper sets `CODEX_LOCAL_BIN_DIR` with makeWrapper's `--set-default` (a user's own setting wins) so a bare profile install always delegates to the bundled component CLI.
3. The comment-checker component resolves `$OMO_COMMENT_CHECKER_BIN` (absolute), then `require('@code-yeongyu/comment-checker')`, then PATH — lazily, on the first edit/write tool result.

### Packaging quirks

- **Shared dependency tree**: the checkout and `bunDeps` come from `omo-common.nix`, so building `omo-senpi` and `omo-cli` together realises the dependency derivation once.
- **node_modules must be copied, not symlinked**: the deps derivation's `@oh-my-opencode/*` entries are relative symlinks into `../packages/*`; placing the tree next to the checkout resolves them, but symlinking the tree itself makes them resolve inside the deps derivation (where `packages/*/package.json` does not exist) and `bun build` fails with `Could not resolve: @oh-my-opencode/utils/...`.
- **No patchShebangs**: unlike the plugin build (which runs `tsc` from `node_modules/.bin`), both `bun build` invocations need no node_modules scripts.
- **`directive.md` layout**: the ulw-loop bundle reads `../directive.md` relative to itself, so it is installed as `$out/lib/ulw-loop/dist/cli.js` + `$out/lib/ulw-loop/directive.md` — the upstream package layout (`dist/cli.js` beside `directive.md`).
- **Scope**: the CLI exists here to serve omo-senpi (`ulw-loop status`, `boulder`). Other subcommands (`install`/`run`/`doctor`) target opencode/codex hosts and are not the supported use in this flake.
- **Unfree**: same Sustainable Use License as omo-senpi; same `NIXPKGS_ALLOW_UNFREE=1 --impure` requirement.

## comment-checker (prebuilt tree-sitter binary)

`comment-checker.nix` fetches the per-platform release archive from [go-claude-code-comment-checker](https://github.com/code-yeongyu/go-claude-code-comment-checker) — the same URL the npm package's `postinstall.js` would download (`comment-checker_v{version}_{os}_{arch}.tar.gz`, GoReleaser `amd64` naming, ~6 MB). The npm package itself is unusable in the sandbox (its postinstall needs network) and bundles all five platforms (~268 MB unpacked).

- **MIT licensed** (the archive ships `LICENSE`), so unlike the omo packages it needs no unfree opt-in.
- **Linux**: the CGO binary links glibc/libgcc and references the FHS ELF interpreter, so `autoPatchelfHook` + `stdenv.cc.cc.lib` rewrite it. Darwin binaries need no treatment.
- **`sourceRoot = "."`**: the archive ships bare files with no top-level directory, which the default unpack phase rejects.
- **No `--version` flag** upstream (clap parser without a version subcommand) — verify with `--help`.
- Versioned independently of the monorepo; `update-omo.sh` tracks `@code-yeongyu/comment-checker/latest` on the npm registry and prefetches all four archives directly (plain `fetchurl` hashes — no placeholder/discovery build), so a comment-checker-only update runs even when the monorepo pin is unchanged.

## Build verification

The CI workflow verifies the build on every PR and push to `main`:
- `nix flake check` — validates flake structure + builds all packages via `checks`
- `nix build .#senpi` — builds the derivation
- Binary exists at `./result/bin/senpi` and is executable
- `pi` alias is a symlink
- `senpi --version` matches the version in `hashes.json`
- `senpi --help` mentions 'senpi'
- `nix build .#omo-senpi` — builds the plugin, then asserts the artifacts `scripts/install.mjs` validates
- `nix build .#omo-cli` — builds the CLI bundle, then:
  - `omo --version` matches `version` in `omo-hashes.json`
  - `omo ulw-loop status --json` in an empty directory exits 1 with a `ULW_LOOP_PLAN_MISSING` JSON body, proving the wrapper's `CODEX_LOCAL_BIN_DIR` default delegates to the bundled component CLI
  - `comment-checker --help` runs (no `--version` flag upstream)
- Real senpi startup with the store path registered must emit omo's `omo-senpi ` component log lines (a path-only check would pass even if the bundle could not load), and with `result-omo-cli/bin` on PATH the log must **not** contain `omo binary not found`

`nix build --rebuild` passes for both `omo-senpi` and `omo-cli` at the current pin (see Packaging quirks). CI does not gate on it — a full second build would double CI time — but run it locally after any `update-omo.sh` bump; a mismatch means upstream regressed bundle determinism.

## Auto-update PR and CI

The auto-update workflow (`.github/workflows/update.yml`) runs daily at 00:00 UTC and can be triggered manually via `workflow_dispatch`. It runs `update.sh` and `update-omo.sh`, verifies both builds, and opens a PR on the `auto-update` branch.

`update-omo.sh` regenerates `omo-npm-packages.json` from the new rev's bun.lock on every bump (byte-identical output when the lockfile is unchanged), and discovers only `lspDaemonNpmDepsHash` via the placeholder build — the bun dependency tree needs no discovery because every tarball carries its lockfile integrity hash. The mismatch scraper accepts both stock Nix (`got: sha256-...`) and Determinate Nix (`To correct the hash mismatch for ..., use "sha256-..."`) wordings, since CI runners use the latter. comment-checker is the other exception: its four release archives are plain `fetchurl` inputs, so `nix-prefetch-url` is authoritative and no discovery build exists for them. The verification at the end of the script builds both `.#omo-senpi` and `.#omo-cli`.

For CI to run automatically on those PRs (via the `pull_request` trigger in `ci.yml`), a **GitHub Personal Access Token (PAT)** must be configured:

1. Create a fine-grained PAT at https://github.com/settings/tokens with:
   - Repository access: `turtton/senpi-flake` only
   - Permissions: **Contents** (Read and write), **Pull requests** (Read and write)
2. Add it as a repository secret: **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `PAT_TOKEN`
   - Value: the PAT you created

Without `PAT_TOKEN`, the workflow falls back to `GITHUB_TOKEN`. PRs are still created, but CI runs must be approved manually on the PR page ("Approve and run").

**Important**: If `PAT_TOKEN` is set but expired or revoked, the expression `${{ secrets.PAT_TOKEN || secrets.GITHUB_TOKEN }}` evaluates the expired token as truthy (non-empty string), so the fallback to `GITHUB_TOKEN` does **not** activate. The `create-pull-request` step will fail with an authentication error. To recover:
- Renew the PAT at https://github.com/settings/tokens
- Update the repository secret with the new token
- Alternatively, delete the `PAT_TOKEN` secret to revert to `GITHUB_TOKEN` behavior

## No tests

There are no unit or integration tests. Verification is: `nix flake check` and all builds succeed, the binaries report the expected versions, `omo ulw-loop` delegates to the bundled component CLI, and senpi loads the omo-senpi plugin from its store path with `omo`/`comment-checker` resolvable on PATH.
