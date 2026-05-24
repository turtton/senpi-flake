{
  lib,
  buildNpmPackage,
  fetchurl,
  fetchFromGitHub,
  jq,
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

  # The npm tarball may ship npm-shrinkwrap.json (which takes precedence over
  # package-lock.json) or omit a lockfile entirely.  We remove any shrinkwrap
  # and inject our committed package-lock.json so buildNpmPackage has a
  # consistent lockfile regardless of upstream's packaging choices.
  #
  # Bundled dependencies (@earendil-works/pi-*) are shipped in node_modules/
  # rather than fetched from the registry; their lockfile entries lack integrity
  # hashes and must be stripped from both the lockfile (done in update.sh) and
  # package.json (done here).  We preserve them in a side directory so they can
  # be restored after npm install (which would otherwise remove them).
  srcWithLock = runCommand "senpi-src-with-lock" { nativeBuildInputs = [ jq ]; } ''
    mkdir -p $out
    tar -xzf ${tarball} -C $out --strip-components=1
    rm -f $out/npm-shrinkwrap.json
    cp ${./package-lock.json} $out/package-lock.json

    # Preserve the entire node_modules/ before we strip bundled deps from
    # package.json.  npm install would remove bundled packages and their
    # transitive dependencies (some of which, like @google/genai, are not
    # declared in the root package.json and therefore won't be re-installed).
    # Stashing the whole tree lets us merge it back after npm install.
    mkdir -p $out/.bundled-deps
    cp -r $out/node_modules $out/.bundled-deps/

    tmp=$(mktemp)
    jq --argjson deps '${builtins.toJSON (versionData.bundledDependencies or versionData.bundleDependencies or [])}' '
      reduce ($deps[] | tostring) as $dep (.;
        del(.dependencies[$dep])
      )
      | del(.bundledDependencies)
      | del(.bundleDependencies)
    ' $out/package.json > "$tmp" && mv "$tmp" $out/package.json
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

  # Restore packages from the tarball's node_modules/ that are absent from
  # npm's installed tree.  Bundled packages (@earendil-works/pi-*) are not on
  # the npm registry and their transitive dependencies (e.g. @google/genai)
  # are absent from the lockfile, so npm never fetches them.  We copy only
  # packages that don't already exist to avoid creating hybrid directories
  # where files from two different versions of the same package coexist.
  postInstall = ''
    bundledDir=$out/lib/node_modules/@code-yeongyu/senpi/node_modules
    srcDir=${srcWithLock}/.bundled-deps/node_modules

    # Copy unscoped packages absent from npm's tree
    for dir in "$srcDir"/*; do
      name=$(basename "$dir")
      if [ ! -e "$bundledDir/$name" ]; then
        cp -a "$dir" "$bundledDir/$name"
      fi
    done

    # Copy @scoped packages absent from npm's tree
    for scopedDir in "$srcDir"/@*; do
      scope=$(basename "$scopedDir")
      mkdir -p "$bundledDir/$scope"
      for pkg in "$scopedDir"/*; do
        name=$(basename "$pkg")
        if [ ! -e "$bundledDir/$scope/$name" ]; then
          cp -a "$pkg" "$bundledDir/$scope/$name"
        fi
      done
    done
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
