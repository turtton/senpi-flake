# senpi-flake — AGENTS.md

Nix flake for [@code-yeongyu/senpi](https://github.com/code-yeongyu/senpi), an npm-published coding agent CLI with bundled native dependencies.

## Repo structure

| File | Purpose |
|---|---|
| `flake.nix` | Flake entrypoint — calls `package.nix` per system, exposes an overlay + checks |
| `package.nix` | Derivation — fetches npm tarball + GitHub source, handles bundled deps, wraps binary |
| `hashes.json` | Version + SRI hashes (sourceHash, assetsSourceHash, npmDepsHash) + bundledDependencies list |
| `package-lock.json` | Committed lockfile for reproducible npm dependency resolution |
| `update.sh` | NPM registry → tarball → npmDepsHash discovery workflow |
| `.github/workflows/ci.yml` | PR/push CI: `nix flake check`, `nix build .#senpi`, binary verification |
| `.github/workflows/update.yml` | Daily cron: `update.sh` → build → PR (with PAT_TOKEN fallback) |
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

# Run flake checks (builds the package)
nix flake check

# Update to latest upstream release
bash update.sh
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

## Build verification

The CI workflow verifies the build on every PR and push to `main`:
- `nix flake check` — validates flake structure + builds the package via `checks`
- `nix build .#senpi` — builds the derivation
- Binary exists at `./result/bin/senpi` and is executable
- `pi` alias is a symlink
- `senpi --version` matches the version in `hashes.json`
- `senpi --help` mentions 'senpi'

## Auto-update PR and CI

The auto-update workflow (`.github/workflows/update.yml`) runs daily at 00:00 UTC and can be triggered manually via `workflow_dispatch`. It runs `update.sh`, verifies the build, and opens a PR on the `auto-update` branch.

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

There are no unit or integration tests. Verification is: `nix flake check && nix build .#senpi` succeeds and the binary reports the expected version.
