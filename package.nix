{
  lib,
  buildNpmPackage,
  fetchurl,
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
    platforms = lib.platforms.all;
    mainProgram = "senpi";
  };
}
