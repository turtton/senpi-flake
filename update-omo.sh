#!/usr/bin/env bash
# Update the omo-senpi package to the latest oh-my-openagent commit.
#
# Strategy:
# 1. Resolve the default branch HEAD of code-yeongyu/oh-my-openagent.
# 2. Prefetch the source with submodules (packages/shared-skills/upstreams/*).
# 3. Regenerate omo-npm-packages.json from the new bun.lock
#    (generate-npm-packages.py).  Every npm tarball is fetched with its
#    lockfile integrity hash, so the dependency tree needs no hash discovery.
# 4. Stamp the lsp-daemon npm deps hash with a placeholder and let
#    `nix build` report the real value (the only remaining discovery FOD).
# 5. Rewrite omo-hashes.json atomically and verify with a real build.
#
# The comment-checker binary (omo-cli/comment-checker.nix) is versioned
# independently of the monorepo, so its update is tracked separately: query
# the npm registry for @code-yeongyu/comment-checker/latest and prefetch the
# four per-platform release archives with plain nix-prefetch-url.  These are
# ordinary fetchurl inputs — no placeholder/discovery build is needed, which
# also means a comment-checker-only update runs even when the monorepo pin is
# unchanged.
#
# omo-senpi carries the Sustainable Use License, so every nix invocation here
# sets NIXPKGS_ALLOW_UNFREE=1 --impure.
set -euo pipefail

REPO="code-yeongyu/oh-my-openagent"
COMMENT_CHECKER_REPO="code-yeongyu/go-claude-code-comment-checker"
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

require_cmd curl jq nix nix-prefetch-url python3

nix_build() {
  nix build .#omo-senpi --impure "$@"
}

# Prefetch a plain (non-unpacked) URL and print its SRI hash.  Matches the
# conversion idiom used by update.sh.
prefetch_sri() {
  local url="$1" hex
  hex=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null | tail -n1)
  if [ -z "$hex" ]; then
    echo "nix-prefetch-url failed for $url" >&2
    exit 1
  fi
  nix --extra-experimental-features nix-command hash convert \
    --hash-algo sha256 --to sri "$hex"
}

set_hash() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  register_temp "$tmp"
  jq --arg v "$value" ".${key} = \$v" "$HASHES_JSON" > "$tmp"
  mv "$tmp" "$HASHES_JSON"
}

discover_hash() {
  local key="$1" fod_name="$2" log new
  set_hash "$key" "$DUMMY_HASH"
  log=$(mktemp)
  register_temp "$log"

  if nix_build --no-link 2> "$log"; then
    echo "Build unexpectedly succeeded with a placeholder $key" >&2
    exit 1
  fi

  # Stock Nix reports fixed-output mismatches per-derivation:
  #   error: hash mismatch in fixed-output derivation '...<fod_name>.drv':
  #     specified: sha256-...
  #     got:       sha256-...
  # Match on the derivation name (2 lines after the error) so multiple
  # discovery FODs don't interfere.
  new=$(
    grep -A2 "hash mismatch in fixed-output derivation.*${fod_name}\.drv" "$log" \
      | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' \
      | head -n1 \
      | sed -E 's/.*(sha256-[A-Za-z0-9+/=]+).*/\1/'
  )

  # Determinate Nix (what nix-installer-action puts on CI runners) reports
  # fixed-output mismatches in a different wording than stock Nix:
  #   error: To correct the hash mismatch for <fod_name>, use "sha256-..."
  if [ -z "$new" ]; then
    new=$(
      grep -oE "To correct the hash mismatch for ${fod_name}, use \"sha256-[A-Za-z0-9+/=]+\"" "$log" \
        | head -n1 \
        | sed -E 's/.*use "(sha256-[A-Za-z0-9+/=]+)".*/\1/'
    )
  fi

  if [ -z "$new" ]; then
    echo "Failed to discover $key. Build log tail:" >&2
    tail -n 30 "$log" >&2
    exit 1
  fi

  echo "Discovered $key: $new" >&2
  set_hash "$key" "$new"
}

current_rev=$(jq -r '.rev' "$HASHES_JSON")
current_cc=$(jq -r '.commentChecker.version' "$HASHES_JSON")

echo "Resolving $REPO HEAD..."
head_json=$(mktemp)
register_temp "$head_json"
curl -fsSL "https://api.github.com/repos/${REPO}/commits/HEAD" > "$head_json"

latest_rev=$(jq -r '.sha' "$head_json")
if [ -z "$latest_rev" ] || [ "$latest_rev" = "null" ]; then
  echo "Failed to resolve HEAD for $REPO" >&2
  exit 1
fi

echo "Resolving latest @code-yeongyu/comment-checker version..."
cc_json=$(mktemp)
register_temp "$cc_json"
curl -fsSL "https://registry.npmjs.org/@code-yeongyu/comment-checker/latest" > "$cc_json"

latest_cc=$(jq -r '.version' "$cc_json")
if [ -z "$latest_cc" ] || [ "$latest_cc" = "null" ]; then
  echo "Failed to resolve latest comment-checker version" >&2
  exit 1
fi

echo "Current: $current_rev (comment-checker $current_cc)"
echo "Latest:  $latest_rev (comment-checker $latest_cc)"

omo_changed=0
cc_changed=0
if [ "$current_rev" != "$latest_rev" ]; then
  omo_changed=1
fi
if [ "$current_cc" != "$latest_cc" ]; then
  cc_changed=1
fi

if [ "$omo_changed" -eq 0 ] && [ "$cc_changed" -eq 0 ]; then
  echo "Already up to date"
  exit 0
fi

# comment-checker is pinned per platform with plain fetchurl hashes, so a
# direct prefetch is authoritative — it never goes through discover_hash.
if [ "$cc_changed" -eq 1 ]; then
  echo "Prefetching comment-checker $latest_cc release archives..."
  cc_base="https://github.com/${COMMENT_CHECKER_REPO}/releases/download/v${latest_cc}/comment-checker_v${latest_cc}"
  sri_linux_amd64=$(prefetch_sri "${cc_base}_linux_amd64.tar.gz")
  sri_linux_arm64=$(prefetch_sri "${cc_base}_linux_arm64.tar.gz")
  sri_darwin_amd64=$(prefetch_sri "${cc_base}_darwin_amd64.tar.gz")
  sri_darwin_arm64=$(prefetch_sri "${cc_base}_darwin_arm64.tar.gz")

  tmp_hashes=$(mktemp)
  register_temp "$tmp_hashes"
  jq --arg v "$latest_cc" \
     --arg xl "$sri_linux_amd64" \
     --arg al "$sri_linux_arm64" \
     --arg xd "$sri_darwin_amd64" \
     --arg ad "$sri_darwin_arm64" \
     '.commentChecker = {version: $v, hashes: {"x86_64-linux": $xl, "aarch64-linux": $al, "x86_64-darwin": $xd, "aarch64-darwin": $ad}}' \
     "$HASHES_JSON" > "$tmp_hashes"
  mv "$tmp_hashes" "$HASHES_JSON"
fi

if [ "$omo_changed" -eq 1 ]; then
  # Version comes from the monorepo root package.json at that revision.
  latest_version=$(
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/${latest_rev}/package.json" \
      | jq -r '.version'
  )
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    echo "Failed to read version from root package.json at $latest_rev" >&2
    exit 1
  fi

  # Submodules are required, so prefetch through nix-prefetch-git rather than
  # the GitHub archive tarball (which omits them).
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

  # bun.lock moved with the rev: regenerate the per-tarball package data.
  # When the lockfile is unchanged the generator output is byte-identical,
  # so this costs nothing in the no-op case.
  echo "Regenerating omo-npm-packages.json from bun.lock at $latest_rev..."
  bun_lock=$(mktemp)
  register_temp "$bun_lock"
  curl -fsSL "https://raw.githubusercontent.com/${REPO}/${latest_rev}/bun.lock" > "$bun_lock"
  python3 generate-npm-packages.py "$bun_lock" omo-npm-packages.json

  # packages/lsp-daemon and packages/omo-codex/plugin each keep their own npm
  # lockfile consumed via fetchNpmDeps; those hashes still need placeholder
  # discovery.  Discover lsp-daemon first (it exists on every rev); the codex
  # plugin hash is only added from 5.0.0-beta.2 on.
  echo "Discovering lspDaemonNpmDepsHash..."
  discover_hash lspDaemonNpmDepsHash omo-senpi-lsp-daemon-npm-deps
  echo "Discovering codexPluginNpmDepsHash..."
  discover_hash codexPluginNpmDepsHash omo-senpi-codex-plugin-npm-deps
fi

# omo-cli embeds the comment-checker binary and shares the monorepo pin, so
# any change above can affect it; omo-senpi itself is unchanged in a
# checker-only run, in which case this build is a cache hit.
echo "Verifying with real build..."
nix_build --no-link
nix build .#omo-cli --impure --no-link

if [ "$omo_changed" -eq 1 ]; then
  echo "Updated omo-senpi to $latest_version ($latest_rev)"
fi
if [ "$cc_changed" -eq 1 ]; then
  echo "Updated comment-checker to $latest_cc"
fi
