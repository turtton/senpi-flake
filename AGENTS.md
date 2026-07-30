# senpi-flake — AGENTS.md

Nix flake for [@code-yeongyu/senpi](https://github.com/code-yeongyu/senpi), an npm-published coding agent CLI with bundled native dependencies.

## Repo structure

| File | Purpose |
|---|---|
| `flake.nix` | Flake entrypoint — calls `package.nix` / `omo-senpi.nix` per system, exposes an overlay + checks |
| `package.nix` | senpi derivation — fetches npm tarball + GitHub source, handles bundled deps, wraps binary |
| `hashes.json` | senpi version + SRI hashes (sourceHash, assetsSourceHash, npmDepsHash) + bundledDependencies list |
| `package-lock.json` | Committed lockfile for reproducible npm dependency resolution |
| `update.sh` | senpi: NPM registry → tarball → npmDepsHash discovery workflow |
| `omo-senpi.nix` | omo-senpi derivation — builds `packages/omo-senpi/plugin` from the oh-my-openagent monorepo |
| `omo-hashes.json` | omo pin: rev, version, srcHash, bunDepsHash, lspDaemonNpmDepsHash |
| `update-omo.sh` | omo: GitHub HEAD → submodule prefetch → two-stage FOD hash discovery |
| `.github/workflows/ci.yml` | PR/push CI: `nix flake check`, both builds, binary + plugin-load verification |
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

# Run flake checks (builds both packages; omo-senpi is unfree)
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure

# Update to latest upstream release (keep both in lockstep)
bash update.sh
bash update-omo.sh

# Build and install the omo-senpi plugin into senpi
NIXPKGS_ALLOW_UNFREE=1 nix build .#omo-senpi --impure
senpi install "$(realpath ./result)/lib/omo-senpi"
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
| `bunDepsHash` | FOD hash of the `bun install` tree |
| `lspDaemonNpmDepsHash` | `fetchNpmDeps` hash for `packages/lsp-daemon` (its own npm lockfile) |

### Packaging quirks

- **Two dependency managers**: the repo is a bun workspace, but `packages/lsp-daemon` is built with `npm ci` against its own `package-lock.json`. The derivation lets `npmConfigHook` populate it (`npmRoot = "packages/lsp-daemon"`) and patches the `npm ci` out of the build script.
- **bun deps as an FOD**: nixpkgs has no bun lockfile fetcher. `bun install` output was verified byte-identical across independent runs (`diff -r` over two installs with separate `HOME`s), so a fixed-output derivation is sound.
- **Per-workspace `node_modules`**: bun creates a `node_modules/` inside each of the 24 workspace packages, and some links exist *only* there — e.g. `packages/omo-senpi/node_modules/@oh-my-opencode/omo-opencode`. Keeping only the root tree makes `bun build` fail to resolve `@oh-my-opencode/omo-opencode/config-migration`.
- **Manifest-only FOD input**: the deps FOD consumes just `package.json` + `bun.lock` + every workspace manifest (including `packages/lsp-daemon`, which is reached via `file:../lsp-daemon` and is absent from the `workspaces` array). Its hash therefore only moves when a manifest or the lockfile moves.
- **Shebangs**: the deps FOD keeps upstream `#!/usr/bin/env node` shebangs so its hash is store-path independent; `configurePhase` runs `patchShebangs` afterwards, otherwise `node_modules/.bin/tsc` fails with `bad interpreter`.
- **Dangling symlinks in the FOD**: `node_modules/@oh-my-opencode/*` are relative links into `../packages/*` and only resolve once copied next to the checkout, so `dontCheckForBrokenSymlinks = true`.
- **Submodule script**: `materialize-shared-upstreams.mjs --strict` runs `git submodule update --init`, impossible in the sandbox. `fetchSubmodules` already supplies the trees, so `postPatch` drops `--strict` to take the script's documented "continuing without submodule refresh" path.
- **Unfree**: Sustainable Use License (non-commercial, free-of-charge distribution only). Every `nix` invocation needs `NIXPKGS_ALLOW_UNFREE=1` and `--impure`.
- **Shebangs in `skills/`**: top-level `dontPatchShebangs = true`. `skills/` ships portable helper scripts (`skills/ast-grep/install.sh`, the `programming` scripts) that the agent runs on the user's machine, so their `#!/usr/bin/env bash` must survive. The `patchShebangs` call inside `configurePhase` is explicit and still runs.
- **Not bit-reproducible**: `nix build --rebuild` reports a mismatch in `extensions/omo.js`. `bun build --minify` picks different mangled identifier names between runs (same length, ~1963 bytes differ, e.g. `class v0` vs `class p0`), which also flips the body digest in omo's own `// omo-senpi-build:<sourceDigest>:<bodyDigest>` marker. Reproduced outside Nix with two plain `node scripts/build-extension.mjs` runs in a normal checkout, so it is upstream toolchain behaviour, not a packaging defect. The source digest stays stable, and functionality is unaffected.

### Runtime facts (verified, not assumed)

- senpi loads local-path packages without copying, so the plugin runs from the read-only store path. Verified: `senpi list` reports the store path, the extension initializes, and `task`/`team_*`/`lsp_*` all register.
- A child agent spawned through `task` runs to completion from the store path.
- All mutable state goes to `$HOME/.omo/` (`lsp-daemon/v0.1.0/daemon.{sock,pid,log,auth}`, `codegraph/`). Nothing is written into the store path.
- Build artifacts contain no build-machine absolute paths.
- `omo binary not found` and `comment-checker binary unavailable` are expected startup lines: those components need the separate `omo` CLI and are skipped without it. The task/team and LSP components do not require it.

### Version coupling

`packages/senpi-task` pins its senpi peer exactly (e.g. `@code-yeongyu/senpi: 2026.7.26`). The extension bundle externalizes the senpi peer family and resolves it from the host at runtime, so a drifting senpi can make components self-skip rather than crash — the task tool would silently disappear. Hence `update.yml` runs `update.sh` and `update-omo.sh` in the same job so both move together.

## Build verification

The CI workflow verifies the build on every PR and push to `main`:
- `nix flake check` — validates flake structure + builds both packages via `checks`
- `nix build .#senpi` — builds the derivation
- Binary exists at `./result/bin/senpi` and is executable
- `pi` alias is a symlink
- `senpi --version` matches the version in `hashes.json`
- `senpi --help` mentions 'senpi'
- `nix build .#omo-senpi` — builds the plugin, then asserts the artifacts `scripts/install.mjs` validates
- Real senpi startup with the store path registered must emit omo's `omo-senpi ` component log lines (a path-only check would pass even if the bundle could not load)

Do not add a `--rebuild` reproducibility gate for `omo-senpi`: `bun build --minify` is not deterministic upstream (see Packaging quirks).

## Auto-update PR and CI

The auto-update workflow (`.github/workflows/update.yml`) runs daily at 00:00 UTC and can be triggered manually via `workflow_dispatch`. It runs `update.sh` and `update-omo.sh`, verifies both builds, and opens a PR on the `auto-update` branch.

`update-omo.sh` discovers `lspDaemonNpmDepsHash` before `bunDepsHash`: the lsp-daemon FOD is realised first, so its mismatch would otherwise mask the bun hash. Each discovery stamps a placeholder, runs a build that is expected to fail, and scrapes `got: sha256-...`.

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

There are no unit or integration tests. Verification is: `nix flake check` and both builds succeed, the binary reports the expected version, and senpi loads the omo-senpi plugin from its store path.
