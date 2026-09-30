#!/usr/bin/env bash
# Track the published OmO Native release, including its exact senpi engine pin.
# The npm tarball already contains the built plugin; no monorepo HEAD, submodules,
# Bun build, or workspace dependency regeneration is needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HASHES_JSON=omo-hashes.json
LOCKFILE=omo-package-lock.json
DUMMY_HASH=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
COMMENT_CHECKER_REPO=code-yeongyu/go-claude-code-comment-checker
export NIXPKGS_ALLOW_UNFREE=1

task_tmp=$(mktemp -d)
published=0
verified=0
cp "$HASHES_JSON" "$task_tmp/original-hashes.json"
if [ -e "$LOCKFILE" ]; then cp "$LOCKFILE" "$task_tmp/original-lock.json"; fi
cleanup() {
  if [ "$published" -eq 1 ] && [ "$verified" -eq 0 ]; then
    cp "$task_tmp/original-hashes.json" "$HASHES_JSON"
    if [ -e "$task_tmp/original-lock.json" ]; then
      cp "$task_tmp/original-lock.json" "$LOCKFILE"
    else
      rm -f "$LOCKFILE"
    fi
    echo "Update failed; restored the previous OmO Native pins and lockfile." >&2
  fi
  rm -rf "$task_tmp"
}
trap cleanup EXIT

for command in curl jq nix nix-prefetch-url tar; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

nix_build() {
  # path: includes a newly generated lockfile before Git has staged it.
  nix --extra-experimental-features 'nix-command flakes' build "path:$PWD#omo-native" --impure "$@"
}

prefetch_sri() {
  local hash
  hash=$(nix-prefetch-url --type sha256 "$1" 2>/dev/null | tail -n1)
  nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$hash"
}

set_hash() {
  jq --arg key "$1" --arg value "$2" '.[$key] = $value' "$HASHES_JSON" > "$task_tmp/hashes-next.json"
  mv "$task_tmp/hashes-next.json" "$HASHES_JSON"
}

requested_version=${1:-latest}
if [ "$#" -gt 1 ] || [[ ! "$requested_version" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.+-]+)?)$ ]]; then
  echo "Usage: $0 [version] (default: latest stable npm release)" >&2
  exit 1
fi
curl -fsSL "https://registry.npmjs.org/omo-ai/$requested_version" > "$task_tmp/metadata.json"
latest_version=$(jq -er '.version' "$task_tmp/metadata.json")
senpi_version=$(jq -er '.dependencies["@code-yeongyu/senpi"] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][A-Za-z0-9.+-]+)?$"))' "$task_tmp/metadata.json")
tarball_url=$(jq -er '.dist.tarball' "$task_tmp/metadata.json")
if [ "$tarball_url" != "https://registry.npmjs.org/omo-ai/-/omo-ai-$latest_version.tgz" ]; then
  echo "Unexpected omo-ai tarball URL: $tarball_url" >&2
  exit 1
fi
current_version=$(jq -r '.version' "$HASHES_JSON")
current_cc=$(jq -r '.commentChecker.version' "$HASHES_JSON")
echo "OmO Native: $current_version -> $latest_version (senpi $senpi_version)"

omo_changed=0
if [ "$current_version" != "$latest_version" ] \
  || [ "$(jq -r '.senpiVersion // ""' "$HASHES_JSON")" != "$senpi_version" ] \
  || ! jq -e --arg dummy "$DUMMY_HASH" '.sourceHash and .npmDepsHash and .npmDepsHash != $dummy' "$HASHES_JSON" >/dev/null \
  || [ ! -f "$LOCKFILE" ] \
  || ! jq -e --arg version "$latest_version" --arg engine "$senpi_version" '.version == $version and .packages[""].dependencies["@code-yeongyu/senpi"] == $engine' "$LOCKFILE" >/dev/null; then
  omo_changed=1
fi
if [ "$omo_changed" -eq 0 ]; then
  echo 'Already up to date'
  exit 0
fi

if [ "$omo_changed" -eq 1 ]; then
  source_hash=$(prefetch_sri "$tarball_url")
  curl -fsSL "$tarball_url" -o "$task_tmp/omo.tgz"
  mkdir "$task_tmp/package"
  tar xzf "$task_tmp/omo.tgz" -C "$task_tmp/package" --strip-components=1
  jq -e --arg version "$latest_version" --arg engine "$senpi_version" \
    '.name == "omo-ai" and .version == $version and .dependencies["@code-yeongyu/senpi"] == $engine' \
    "$task_tmp/package/package.json" >/dev/null
  # Native's bundled downloader pins its own tested checker release. Follow
  # that pin rather than an independent npm dist-tag. Fail on an unfamiliar
  # bundle layout so an update cannot silently select an unrelated version.
  latest_cc=$(jq -Rers '[match("(?:var|let|const) [A-Za-z_$][A-Za-z0-9_$]*=\"(?<version>[0-9]+\\.[0-9]+\\.[0-9]+)\",[A-Za-z_$][A-Za-z0-9_$]*=\\{\"darwin-arm64\""; "g").captures[] | select(.name == "version").string] | if length == 1 then .[0] else error("comment-checker pin layout changed") end' "$task_tmp/package/plugin/extensions/omo.js")
  echo "comment-checker: $current_cc -> $latest_cc (Native bundled pin)"
  rm -f "$task_tmp/package/npm-shrinkwrap.json" "$task_tmp/package/package-lock.json"
  # Pin npm as well as Node to the flake's nixpkgs, independently of the user's
  # installed npm version. Node 24 is the engine floor for both omo and senpi.
  # shellcheck disable=SC2016 # This interpolation belongs to Nix.
  node_package=$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths --impure \
    --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.nodejs_24')
  (cd "$task_tmp/package" && PATH="$node_package/bin:$PATH" npm install --package-lock-only --ignore-scripts --no-audit --no-fund)

  jq --arg version "$latest_version" --arg engine "$senpi_version" --arg hash "$source_hash" --arg dummy "$DUMMY_HASH" \
    '{version: $version, senpiVersion: $engine, sourceHash: $hash, npmDepsHash: $dummy, commentChecker: .commentChecker}' \
    "$HASHES_JSON" > "$task_tmp/hashes-next.json"
  published=1
  cp "$task_tmp/package/package-lock.json" "$LOCKFILE"
  mv "$task_tmp/hashes-next.json" "$HASHES_JSON"
fi

if [ "$current_cc" != "$latest_cc" ]; then
  cc_base="https://github.com/$COMMENT_CHECKER_REPO/releases/download/v$latest_cc/comment-checker_v$latest_cc"
  cc_xl=$(prefetch_sri "${cc_base}_linux_amd64.tar.gz")
  cc_al=$(prefetch_sri "${cc_base}_linux_arm64.tar.gz")
  cc_xd=$(prefetch_sri "${cc_base}_darwin_amd64.tar.gz")
  cc_ad=$(prefetch_sri "${cc_base}_darwin_arm64.tar.gz")
  jq --arg version "$latest_cc" --arg xl "$cc_xl" --arg al "$cc_al" --arg xd "$cc_xd" --arg ad "$cc_ad" \
    '.commentChecker = {version: $version, hashes: {"x86_64-linux": $xl, "aarch64-linux": $al, "x86_64-darwin": $xd, "aarch64-darwin": $ad}}' \
    "$HASHES_JSON" > "$task_tmp/hashes-next.json"
  published=1
  mv "$task_tmp/hashes-next.json" "$HASHES_JSON"
fi

if [ "$omo_changed" -eq 1 ]; then
  echo 'Discovering npm dependency hash...'
  if nix_build --no-link > "$task_tmp/discovery.log" 2>&1; then
    echo 'Build unexpectedly succeeded with a placeholder npmDepsHash' >&2
    exit 1
  fi
  # Handle both stock Nix and Determinate Nix without a failing grep pipeline
  # aborting under set -o pipefail before the alternative format is inspected.
  npm_hash=$(awk -v name="omo-native-$latest_version-npm-deps" '
    /To correct the hash mismatch/ && index($0, name) {
      sub(/^.*use "/, ""); sub(/".*$/, ""); print; exit
    }
    /hash mismatch in fixed-output derivation/ { matching = index($0, name) > 0 }
    matching && /got:[[:space:]]+sha256-/ {
      sub(/^.*got:[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }
  ' "$task_tmp/discovery.log")
  if [[ ! "$npm_hash" =~ ^sha256-[A-Za-z0-9+/=]+$ ]]; then
    echo 'Failed to discover npmDepsHash. Build log:' >&2
    tail -n 80 "$task_tmp/discovery.log" >&2
    exit 1
  fi
  set_hash npmDepsHash "$npm_hash"
fi

nix_build --no-link
verified=1
echo "Updated OmO Native to $latest_version (senpi $senpi_version)."
