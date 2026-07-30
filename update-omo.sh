#!/usr/bin/env bash
# Update the omo-senpi package to the latest oh-my-openagent commit.
#
# Strategy:
# 1. Resolve the default branch HEAD of code-yeongyu/oh-my-openagent.
# 2. Prefetch the source with submodules (packages/shared-skills/upstreams/*).
# 3. Stamp the two dependency hashes with placeholders and let `nix build`
#    report the real values, one FOD at a time.
# 4. Rewrite omo-hashes.json atomically and verify with a real build.
#
# omo-senpi carries the Sustainable Use License, so every nix invocation here
# sets NIXPKGS_ALLOW_UNFREE=1 --impure.
set -euo pipefail

REPO="code-yeongyu/oh-my-openagent"
HASHES_JSON="omo-hashes.json"
DUMMY_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

export NIXPKGS_ALLOW_UNFREE=1

_cleanup_items=()

register_temp() {
  for item in "$@"; do
    _cleanup_items+=("$item")
  done
}

cleanup() {
  local item
  for item in "${_cleanup_items[@]:-}"; do
    if [ -e "$item" ] || [ -L "$item" ]; then
      rm -rf -- "$item"
    fi
  done
}

trap cleanup EXIT

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

require_cmd curl jq nix

nix_build() {
  nix build .#omo-senpi --impure "$@"
}

set_hash() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  register_temp "$tmp"
  if [ "$key" = "bunDepsHash" ]; then
    local system
    system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
    jq --arg v "$value" --arg s "$system" '.bunDepsHash[$s] = $v' "$HASHES_JSON" > "$tmp"
  else
    jq --arg v "$value" ".${key} = \$v" "$HASHES_JSON" > "$tmp"
  fi
  mv "$tmp" "$HASHES_JSON"
}

discover_hash() {
  local key="$1" log new
  set_hash "$key" "$DUMMY_HASH"
  log=$(mktemp)
  register_temp "$log"

  if nix_build --no-link 2> "$log"; then
    echo "Build unexpectedly succeeded with a placeholder $key" >&2
    exit 1
  fi

  new=$(
    grep -E '^[[:space:]]*got:[[:space:]]+sha256-' "$log" \
      | head -n1 \
      | sed -E 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/'
  )

  if [ -z "$new" ]; then
    echo "Failed to discover $key. Build log tail:" >&2
    tail -n 30 "$log" >&2
    exit 1
  fi

  echo "Discovered $key: $new" >&2
  set_hash "$key" "$new"
}

current_rev=$(jq -r '.rev' "$HASHES_JSON")

echo "Resolving $REPO HEAD..."
head_json=$(mktemp)
register_temp "$head_json"
curl -fsSL "https://api.github.com/repos/${REPO}/commits/HEAD" > "$head_json"

latest_rev=$(jq -r '.sha' "$head_json")
if [ -z "$latest_rev" ] || [ "$latest_rev" = "null" ]; then
  echo "Failed to resolve HEAD for $REPO" >&2
  exit 1
fi

echo "Current: $current_rev"
echo "Latest:  $latest_rev"

if [ "$current_rev" = "$latest_rev" ]; then
  echo "Already up to date"
  exit 0
fi

# Version comes from the monorepo root package.json at that revision.
latest_version=$(
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/${latest_rev}/package.json" \
    | jq -r '.version'
)
if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
  echo "Failed to read version from root package.json at $latest_rev" >&2
  exit 1
fi

# Submodules are required, so prefetch through nix-prefetch-git rather than the
# GitHub archive tarball (which omits them).
echo "Prefetching source with submodules (this clones the repo)..."
prefetch_json=$(
  nix --extra-experimental-features 'nix-command flakes' \
    run nixpkgs#nix-prefetch-git -- \
    --url "https://github.com/${REPO}" \
    --rev "$latest_rev" \
    --fetch-submodules \
    --quiet
)
new_src_hash=$(jq -r '.hash' <<< "$prefetch_json")
if [ -z "$new_src_hash" ] || [ "$new_src_hash" = "null" ]; then
  echo "nix-prefetch-git did not report a hash" >&2
  exit 1
fi

tmp_hashes=$(mktemp)
register_temp "$tmp_hashes"
jq --arg rev "$latest_rev" \
   --arg v "$latest_version" \
   --arg sh "$new_src_hash" \
   '. + {rev: $rev, version: $v, srcHash: $sh}' \
   "$HASHES_JSON" > "$tmp_hashes"
mv "$tmp_hashes" "$HASHES_JSON"

# The lsp-daemon npm deps FOD is evaluated before the bun deps FOD, so discover
# it first; otherwise its mismatch masks the bun hash.
echo "Discovering lspDaemonNpmDepsHash..."
discover_hash lspDaemonNpmDepsHash

echo "Discovering bunDepsHash..."
discover_hash bunDepsHash

echo "Verifying with real build..."
nix_build --no-link

echo "Updated omo-senpi to $latest_version ($latest_rev)"
