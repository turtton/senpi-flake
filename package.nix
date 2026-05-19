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

    install -Dm644 "$srcRoot"/modes/interactive/theme/dark.json         dist/modes/interactive/theme/dark.json
    install -Dm644 "$srcRoot"/modes/interactive/theme/light.json        dist/modes/interactive/theme/light.json
    install -Dm644 "$srcRoot"/modes/interactive/theme/theme-schema.json dist/modes/interactive/theme/theme-schema.json

    install -Dm644 "$srcRoot"/modes/interactive/assets/clankolas.png    dist/modes/interactive/assets/clankolas.png

    install -Dm644 "$srcRoot"/core/export-html/template.html            dist/core/export-html/template.html
    install -Dm644 "$srcRoot"/core/export-html/template.css             dist/core/export-html/template.css
    install -Dm644 "$srcRoot"/core/export-html/template.js              dist/core/export-html/template.js
    install -Dm644 "$srcRoot"/core/export-html/vendor/highlight.min.js  dist/core/export-html/vendor/highlight.min.js
    install -Dm644 "$srcRoot"/core/export-html/vendor/marked.min.js     dist/core/export-html/vendor/marked.min.js
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
