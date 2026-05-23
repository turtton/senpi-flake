#!/usr/bin/env bash
# Update senpi-flake to the latest @code-yeongyu/senpi version on npm.
#
# Strategy:
# 1. Query the npm registry for the latest version + tarball integrity (SRI base64).
# 2. Strip bundledDependencies from package.json, remove npm-shrinkwrap.json and
#    node_modules/ from the extracted tarball, then regenerate package-lock.json
#    via `npm install --package-lock-only --ignore-scripts` in a clean directory.
# 3. Stamp npmDepsHash with a placeholder and let `nix build` discover the real one.
# 4. Rewrite hashes.json atomically.
#
# Uses POSIX-compatible bash (no associative arrays) so it runs on macOS bash 3.2.
set -euo pipefail

NPM_PACKAGE="@code-yeongyu/senpi"
HASHES_JSON="hashes.json"
LOCKFILE="package-lock.json"

# Placeholder used while letting Nix discover npmDepsHash.
DUMMY_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

require_cmd curl jq nix nix-prefetch-url tar

current_version=$(jq -r '.version' "$HASHES_JSON")

# Fetch latest version metadata from the npm registry.
meta_json=$(mktemp)
trap 'rm -f "$meta_json"' EXIT

latest_version=$(
  curl -fsSL "https://registry.npmjs.org/${NPM_PACKAGE}/latest" \
    | tee "$meta_json" \
    | jq -r '.version'
)

if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
  echo "Failed to fetch latest version metadata from npm registry" >&2
  exit 1
fi

echo "Current: $current_version"
echo "Latest:  $latest_version"

if [ "$current_version" = "$latest_version" ]; then
  echo "Already up to date"
  exit 0
fi

tarball_url=$(jq -r '.dist.tarball' "$meta_json")

if [ -z "$tarball_url" ] || [ "$tarball_url" = "null" ]; then
  echo "Tarball URL missing in registry metadata" >&2
  exit 1
fi

# The npm registry's integrity field is already SRI-formatted (e.g. "sha512-..." or
# "sha256-..."). buildNpmPackage's npmDepsHash uses sha256 NAR-style SRI which differs
# from the tarball hash, but `fetchurl` accepts the registry's SRI directly when it
# matches what `nix-prefetch-url` would produce.
#
# Concretely: we re-derive sourceHash via nix-prefetch-url + nix hash convert so the
# stored value is always sha256-* SRI (npm sometimes ships sha512).
echo "Prefetching tarball hash..."
prefetch_hex=$(nix-prefetch-url --type sha256 "$tarball_url" 2>/dev/null | tail -n1)
if [ -z "$prefetch_hex" ]; then
  echo "nix-prefetch-url failed for $tarball_url" >&2
  exit 1
fi
new_source_hash=$(
  nix --extra-experimental-features nix-command hash convert \
    --hash-algo sha256 --to sri "$prefetch_hex"
)

# Prefetch the GitHub source tarball for the matching tag (used to inject
# assets that upstream's copy-assets script would have built into dist/).
echo "Prefetching GitHub source tarball for assets..."
assets_url="https://github.com/code-yeongyu/senpi/archive/refs/tags/v${latest_version}.tar.gz"
assets_prefetch_hex=$(nix-prefetch-url --unpack --type sha256 "$assets_url" 2>/dev/null | tail -n1)
if [ -z "$assets_prefetch_hex" ]; then
  echo "nix-prefetch-url failed for $assets_url" >&2
  exit 1
fi
new_assets_source_hash=$(
  nix --extra-experimental-features nix-command hash convert \
    --hash-algo sha256 --to sri "$assets_prefetch_hex"
)

# Regenerate package-lock.json against the latest tarball.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir" "$meta_json"' EXIT
echo "Downloading tarball and regenerating $LOCKFILE..."
curl -fsSL "$tarball_url" -o "$workdir/pkg.tgz"
tar -xzf "$workdir/pkg.tgz" -C "$workdir"

# Strip bundled dependencies from package.json before generating the lockfile.
# Bundled deps (@earendil-works/pi-*) are shipped in node_modules/ rather than
# fetched from the registry; their lockfile entries lack "integrity" hashes,
# which causes buildNpmPackage's fetcher to panic.  We remove them from
# package.json so they are not included in the lockfile; package.nix restores
# the entire tarball node_modules/ (bundled packages + their transitive deps)
# from .bundled-deps/ after npm install.
jq 'del(.dependencies["@earendil-works/pi-agent-core"]) |
    del(.dependencies["@earendil-works/pi-ai"]) |
    del(.dependencies["@earendil-works/pi-tui"]) |
    del(.bundledDependencies)' \
  "$workdir/package/package.json" > "$workdir/package/package.json.tmp" \
  && mv "$workdir/package/package.json.tmp" "$workdir/package/package.json"

# Remove any npm-shrinkwrap.json (takes precedence over package-lock.json and
# would prevent npm from generating a fresh lockfile) and the pre-bundled
# node_modules/ (which causes npm to produce incomplete lockfile entries
# missing "resolved"/"integrity" fields for packages already present locally).
rm -f "$workdir/package/npm-shrinkwrap.json" "$workdir/package/package-lock.json"
rm -rf "$workdir/package/node_modules"

# Generate a clean lockfile from the stripped package.json in a pristine
# directory (no pre-existing node_modules/ to confuse npm).
( cd "$workdir/package" && nix shell nixpkgs#nodejs_24 -c npm install --package-lock-only --ignore-scripts >/dev/null )
cp "$workdir/package/package-lock.json" "$LOCKFILE"

# Write hashes.json with placeholder for npmDepsHash, then let Nix discover it.
tmp_hashes=$(mktemp)
jq --arg v "$latest_version" \
   --arg sh "$new_source_hash" \
   --arg ah "$new_assets_source_hash" \
   --arg dh "$DUMMY_HASH" \
   '. + {version: $v, sourceHash: $sh, assetsSourceHash: $ah, npmDepsHash: $dh}' \
   "$HASHES_JSON" > "$tmp_hashes"
mv "$tmp_hashes" "$HASHES_JSON"

# Trigger a build to discover the real npmDepsHash.
echo "Discovering npmDepsHash via nix build..."
build_log=$(mktemp)
trap 'rm -rf "$workdir" "$meta_json" "$build_log"' EXIT
if nix build .#senpi --no-link 2> "$build_log"; then
  echo "Build unexpectedly succeeded with placeholder hash" >&2
  exit 1
fi

# Extract the actual hash from "got: sha256-..." in the build log.
new_npm_deps_hash=$(
  grep -E '^[[:space:]]*got:[[:space:]]+sha256-' "$build_log" \
    | head -n1 \
    | sed -E 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/'
)

if [ -z "$new_npm_deps_hash" ]; then
  echo "Failed to discover npmDepsHash. Build log tail:" >&2
  tail -n 30 "$build_log" >&2
  exit 1
fi

echo "Discovered npmDepsHash: $new_npm_deps_hash"

tmp_hashes=$(mktemp)
jq --arg dh "$new_npm_deps_hash" '.npmDepsHash = $dh' "$HASHES_JSON" > "$tmp_hashes"
mv "$tmp_hashes" "$HASHES_JSON"

# Final verification: real build must now succeed.
echo "Verifying with real build..."
nix build .#senpi --no-link

echo "Updated senpi-flake to $latest_version"
