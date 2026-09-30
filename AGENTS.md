# senpi-flake — maintainer notes

This flake packages the published [OmO Native](https://github.com/code-yeongyu/oh-my-openagent) npm distribution (`omo-ai`) and the standalone [senpi](https://github.com/code-yeongyu/senpi) CLI.

## Package layout

| File | Purpose |
|---|---|
| `flake.nix` | Outputs for four systems; default is OmO Native |
| `omo-native.nix` | Builds the published `omo-ai` tarball with its pinned senpi dependency and staged plugin |
| `omo-hashes.json` | OmO version, tarball hash, exact senpi pin, npm dependency hash, comment-checker hashes |
| `omo-package-lock.json` | Committed lockfile for the native npm dependency tree |
| `update-omo.sh` | Updates from npm `omo-ai/latest` and discovers the new dependency hash |
| `package.nix` | Standalone senpi derivation from npm plus matching GitHub source assets |
| `hashes.json`, `package-lock.json` | Standalone senpi version, hashes, and npm lockfile |
| `update.sh` | Updates standalone senpi to an explicit version (or npm latest when omitted) |
| `comment-checker.nix` | Per-system prebuilt comment-checker binary |
| `.github/workflows/update.yml` | Daily npm update, build, and pull request |
| `.github/workflows/ci.yml` | Linux and macOS flake checks and runtime smoke tests |

## Why the native package is the unit of distribution

Upstream installs OmO Native with `bun add -g omo-ai` (or `npm i -g omo-ai`). Its npm tarball already contains `bin/omo.js` and a built `plugin/` payload; its manifest depends on one exact senpi version. The launcher applies OmO branding and invokes that engine with the plugin. Building the old monorepo source into separate `omo-senpi` and `omo-cli` derivations could drift from the published native product and required a large, unstable bun dependency assembly path. This flake follows the published package and keeps compatibility output names:

- `omo-cli` aliases `omo-native`.
- `omo-senpi` exposes the published plugin at `lib/omo-senpi` for existing explicit senpi installations.
- `senpi` remains a standalone package, pinned to the exact version required by the current `omo-ai` release during automated updates.

The native launcher and plugin may attempt first-run preparation. `omo-native.nix` must perform all package-file mutations at build time; Nix store files are read-only at runtime. Keep its launcher and plugin smoke tests in CI when changing this behavior.

## Updating

`update-omo.sh` reads the stable npm `omo-ai/latest` metadata, rather than the oh-my-openagent Git HEAD. It stores the published tarball hash and exact `@code-yeongyu/senpi` dependency version, regenerates `omo-package-lock.json`, discovers `npmDepsHash`, and verifies the native build. The daily workflow then invokes `update.sh "$(jq -r '.senpiVersion' omo-hashes.json)"` so the standalone engine stays in lockstep.

`update.sh` strips any tarball-bundled dependency declarations before lockfile generation. Older senpi releases shipped a `node_modules/` tree, which `package.nix` preserves and restores. New releases publish those packages as npm aliases and omit `node_modules/`; the derivation handles both shapes. The updater accepts stock Nix `got: sha256-...` and Determinate Nix's `To correct the hash mismatch ... use "sha256-..."` wording.

To update locally:

```sh
NIXPKGS_ALLOW_UNFREE=1 ./update-omo.sh
./update.sh "$(jq -r '.senpiVersion' omo-hashes.json)"
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
```

## Verification

CI builds `omo-native` and `senpi` on Linux and macOS, checks the installed native launcher/plugin and senpi version, and verifies the compatibility plugin output. Locally, run:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
NIXPKGS_ALLOW_UNFREE=1 nix build .#omo-native --impure
./result/bin/omo --version
./result/bin/omo doctor
```

The OmO package uses the Sustainable Use License and is unfree in nixpkgs. The comment-checker package is MIT licensed. Every Nix evaluation involving OmO needs `NIXPKGS_ALLOW_UNFREE=1` and `--impure`.

## Auto-update PR credentials

`.github/workflows/update.yml` uses `PAT_TOKEN` when available and falls back to `GITHUB_TOKEN`. A fine-grained PAT for this repository needs Contents and Pull requests read/write permissions. PRs created with only `GITHUB_TOKEN` may require a manual CI run. An expired but nonempty `PAT_TOKEN` prevents the fallback; renew or remove that secret.
