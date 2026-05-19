{
  lib,
  buildNpmPackage,
  fetchurl,
  fetchFromGitHub,
  makeWrapper,
  nodejs_24,
  runCommand,
}:

let
  versionData = lib.importJSON ./hashes.json;
  version = versionData.version;

  tarball = fetchurl {
    url = "https://registry.npmjs.org/@code-yeongyu/senpi/-/senpi-${version}.tgz";
    hash = versionData.sourceHash;
  };

  # Upstream's `copy-assets` build script (which would normally populate dist/
  # with non-JS assets like theme JSON, PNG, HTML templates, and vendored JS)
  # is not run when consuming the npm tarball. We fetch the source tree from
  # GitHub at the matching tag and inject those assets into dist/ ourselves.
  assetsSrc = fetchFromGitHub {
    owner = "code-yeongyu";
    repo = "senpi";
    rev = "v${version}";
    hash = versionData.assetsSourceHash;
  };

  # The npm tarball does not ship package-lock.json, so we generate one out-of-band
  # (committed at the flake root) and inject it into the source tree before npm install.
  srcWithLock = runCommand "senpi-src-with-lock" { } ''
    mkdir -p $out
    tar -xzf ${tarball} -C $out --strip-components=1
    cp ${./package-lock.json} $out/package-lock.json
  '';
in
buildNpmPackage {
  pname = "senpi";
  inherit version;

  src = srcWithLock;

  npmDepsHash = versionData.npmDepsHash;
  npmDepsFetcherVersion = 2;
  makeCacheWritable = true;

  # The npm tarball already ships dist/, no build step required.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  # Inject assets that upstream's `copy-assets` script would have placed in dist/.
  # Mirrors the destinations from packages/coding-agent/package.json scripts.
  postPatch = ''
    srcRoot=${assetsSrc}/packages/coding-agent/src

    # Each entry: "<relative dir> <shell glob>" — mirrors upstream copy-assets
    # exactly (see packages/coding-agent/package.json scripts.copy-assets) so we
    # do not accidentally ship TypeScript sources or other non-asset files.
    copyGlob() {
      local dir="$1"
      local glob="$2"
      if [ ! -d "$srcRoot/$dir" ]; then
        echo "ERROR: expected asset directory $srcRoot/$dir not found (upstream layout changed?)" >&2
        exit 1
      fi
      mkdir -p "dist/$dir"
      shopt -s nullglob
      local matched=("$srcRoot/$dir"/$glob)
      shopt -u nullglob
      if [ ''${#matched[@]} -eq 0 ]; then
        echo "ERROR: no files matched $srcRoot/$dir/$glob (upstream layout changed?)" >&2
        exit 1
      fi
      cp "''${matched[@]}" "dist/$dir/"
    }

    copyGlob modes/interactive/theme       '*.json'
    copyGlob modes/interactive/assets      '*.png'
    copyGlob core/export-html/vendor       '*.js'

    # core/export-html/ gets three specific files (not a glob) — upstream does
    # the same to avoid pulling sources like template.ts.
    mkdir -p dist/core/export-html
    for f in template.html template.css template.js; do
      if [ ! -f "$srcRoot/core/export-html/$f" ]; then
        echo "ERROR: expected $srcRoot/core/export-html/$f not found" >&2
        exit 1
      fi
      cp "$srcRoot/core/export-html/$f" dist/core/export-html/
    done

    chmod -R u+w dist
  '';

  # senpi requires Node.js 24+ at runtime.
  postFixup = ''
    wrapProgram $out/bin/senpi \
      --prefix PATH : ${lib.makeBinPath [ nodejs_24 ]}

    # pi alias for compatibility with upstream's binary name.
    ln -s $out/bin/senpi $out/bin/pi
  '';

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management";
    homepage = "https://github.com/code-yeongyu/senpi";
    changelog = "https://github.com/code-yeongyu/senpi/releases";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    mainProgram = "senpi";
  };
}
