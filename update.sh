#!/usr/bin/env bash
set -euo pipefail

REPO="code-yeongyu/senpi"
PACKAGE_NIX="package.nix"

current_version=$(awk -F'"' '/version = / { print $2; exit }' "$PACKAGE_NIX")

latest_tag=$(curl -sf "https://api.github.com/repos/${REPO}/releases/latest" \
  | jq -r '.tag_name')

if [ -z "$latest_tag" ] || [ "$latest_tag" = "null" ]; then
  echo "Failed to fetch latest release tag"
  exit 1
fi

latest_version="${latest_tag#v}"

echo "Current: $current_version"
echo "Latest:  $latest_version"

if [ "$current_version" = "$latest_version" ]; then
  echo "Already up to date"
  exit 0
fi

echo "Updating to $latest_version..."

declare -A PLATFORM_SUFFIXES=(
  ["x86_64-linux"]="linux-x64"
  ["aarch64-linux"]="linux-arm64"
  ["x86_64-darwin"]="darwin-x64"
  ["aarch64-darwin"]="darwin-arm64"
)

update_file() {
  local file="$1" pattern="$2" replacement="$3"
  local tmp="${file}.tmp"
  sed "s|${pattern}|${replacement}|" "$file" > "$tmp" && mv "$tmp" "$file"
}

# Pre-flight: verify all platform tarballs exist before mutating package.nix,
# so a partial release (e.g. arm64 still uploading) does not leave package.nix half-updated.
declare -A NEW_HASHES=()
for system in "${!PLATFORM_SUFFIXES[@]}"; do
  suffix="${PLATFORM_SUFFIXES[$system]}"
  asset_url="https://github.com/${REPO}/releases/download/${latest_tag}/pi-${suffix}.tar.gz"

  echo "Probing $suffix ..."
  http_code=$(curl -sIL -o /dev/null -w '%{http_code}' "$asset_url" || true)

  if [ "$http_code" = "404" ]; then
    echo "Asset not yet published for $suffix (HTTP 404). Aborting update — will retry on next run."
    exit 0
  fi

  if [ "$http_code" != "200" ]; then
    echo "Unexpected HTTP $http_code for $suffix"
    exit 1
  fi

  echo "Computing SRI hash for $suffix ..."
  new_hash=$(nix-prefetch-url --type sha256 "$asset_url" 2>/dev/null \
    | tail -n1)

  if [ -z "$new_hash" ]; then
    echo "Failed to compute hash for $suffix"
    exit 1
  fi

  sri_hash=$(nix --extra-experimental-features nix-command hash to-sri --type sha256 "$new_hash")

  NEW_HASHES[$system]="$sri_hash"
  echo "  $system: $sri_hash"
done

for system in "${!PLATFORM_SUFFIXES[@]}"; do
  old_hash=$(awk -v sys="\"$system\"" '
    $0 ~ sys { found=1; next }
    found && /hash = / { sub(/.*hash = "/, ""); sub(/";.*/, ""); print; exit }
  ' "$PACKAGE_NIX")

  if [ -z "$old_hash" ]; then
    echo "Could not locate existing hash for $system in $PACKAGE_NIX"
    exit 1
  fi

  update_file "$PACKAGE_NIX" "$old_hash" "${NEW_HASHES[$system]}"
done

update_file "$PACKAGE_NIX" "version = \"${current_version}\"" "version = \"${latest_version}\""

echo "Updated package.nix to version $latest_version"
