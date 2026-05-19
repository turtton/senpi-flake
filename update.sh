#!/usr/bin/env bash
# Update senpi-flake to the latest @code-yeongyu/senpi version on npm.
#
# Strategy:
# 1. Query the npm registry for the latest version + tarball integrity (SRI base64).
# 2. Regenerate package-lock.json via `npm install --package-lock-only --ignore-scripts`
#    inside the freshly extracted tarball.
# 3. Stamp npmDepsHash with a placeholder and let `nix build` discover the real one.
# 4. Rewrite hashes.json atomically.
#
# Uses POSIX-compatible bash (no associative arrays) so it runs on macOS bash 3.2.
set -euo pipefail

NPM_PACKAGE="@code-yeongyu/senpi"
HASHES_JSON="hashes.json"
LOCKFILE="package-lock.json"
PACKAGE_NIX="package.nix"

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

require_cmd curl jq nix npm tar

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
integrity=$(jq -r '.dist.integrity' "$meta_json")

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

# Regenerate package-lock.json against the latest tarball.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir" "$meta_json"' EXIT
echo "Downloading tarball and regenerating $LOCKFILE..."
curl -fsSL "$tarball_url" -o "$workdir/pkg.tgz"
tar -xzf "$workdir/pkg.tgz" -C "$workdir"
( cd "$workdir/package" && npm install --package-lock-only --ignore-scripts >/dev/null )
cp "$workdir/package/package-lock.json" "$LOCKFILE"

# Write hashes.json with placeholder for npmDepsHash, then let Nix discover it.
tmp_hashes=$(mktemp)
jq --arg v "$latest_version" \
   --arg sh "$new_source_hash" \
   --arg dh "$DUMMY_HASH" \
   '. + {version: $v, sourceHash: $sh, npmDepsHash: $dh}' \
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
