{
  lib,
  buildNpmPackage,
  fetchurl,
  makeWrapper,
  nodejs_24,
  runCommand,
  comment-checker ? null,
}:

let
  pin = lib.importJSON ./omo-hashes.json;
  tarball = fetchurl {
    url = "https://registry.npmjs.org/omo-ai/-/omo-ai-${pin.version}.tgz";
    hash = pin.sourceHash;
  };
  srcWithLock = runCommand "omo-native-src-with-lock" { } ''
    mkdir -p $out
    tar -xzf ${tarball} -C $out --strip-components=1
    rm -f $out/npm-shrinkwrap.json
    cp ${./omo-package-lock.json} $out/package-lock.json
  '';
in
(buildNpmPackage.override { nodejs = nodejs_24; }) {
  pname = "omo-native";
  version = pin.version;
  src = srcWithLock;
  npmDepsHash = pin.npmDepsHash;
  npmDepsFetcherVersion = 2;
  makeCacheWritable = true;
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];

  # The published package includes the complete Native plugin and the exact
  # engine dependency. Run its preparation while both trees are writable;
  # the stamp prevents attempts to patch the engine in the read-only store.
  postInstall = ''
    ${lib.optionalString (comment-checker != null) ''
      ln -s ${comment-checker}/bin/comment-checker $out/bin/comment-checker
    ''}
    packageDir=$out/lib/node_modules/omo-ai
    node "$packageDir/bin/senpi-patch.mjs"

    # Upstream expects a user-owned npm install. A root-owned, immutable Nix
    # store launch spec is also trusted. Keep every other ownership and mode
    # check, and restrict this exception to this derivation's exact spec path.
    export OMO_NIX_PACKAGE_DIR="$packageDir"
    node --input-type=module <<'JS'
    import { readFileSync, writeFileSync } from 'node:fs';
    import { createHash } from 'node:crypto';
    const root = process.env.OMO_NIX_PACKAGE_DIR;
    const spec = JSON.stringify(root + '/plugin/daemon-launch-spec.json');
    const doctor = root + '/bin/lib/launch-spec-mode.js';
    let source = readFileSync(doctor, 'utf8');
    const ownerCheck = 'if (uid !== undefined && stat.uid !== uid) {';
    if (source.split(ownerCheck).length !== 2) throw new Error('omo launch spec doctor ownership check changed');
    source = source.replace(ownerCheck, 'if (uid !== undefined && stat.uid !== uid && !(stat.uid === 0 && path === ' + spec + ')) {');
    writeFileSync(doctor, source);

    const task = root + '/plugin/extensions/omo-task.js';
    source = readFileSync(task, 'utf8');
    const taskOwnerCheck = /if\(void 0!==([\w$]+)&&([\w$]+)!==\1\)throw new ([\w$]+)\("launch_spec_insecure",\x60launch_spec_insecure: \$\{([\w$]+)\}\x60\)/g;
    if ([...source.matchAll(taskOwnerCheck)].length !== 1) throw new Error('omo task launch spec ownership check changed');
    source = source.replace(taskOwnerCheck, (match, uid, owner, error, path) =>
      match.replace(')throw', '&&!(' + owner + '===0&&' + path + '===' + spec + '))throw'));
    // Preserve the upstream build marker's body digest after patching.
    const newline = source.indexOf('\n');
    const marker = source.slice(0, newline).split(':');
    if (marker.length !== 3 || marker[0] !== '// omo') throw new Error('omo task build marker changed');
    const body = source.slice(newline + 1);
    marker[2] = createHash('sha256').update(body).digest('base64url');
    writeFileSync(task, marker.join(':') + '\n' + body);

    const paths = root + '/bin/lib/package-paths.js';
    source = readFileSync(paths, 'utf8');
    const updateReturn = '  // A resolved target installs that exact version; without one the channel spec is the only answer.';
    if (source.split(updateReturn).length !== 2) throw new Error('omo update target entry changed');
    source = source.replace(updateReturn, '  return { manager: "Nix", command: "update the senpi-flake input or Nix profile and rebuild", argv: [] };\n' + updateReturn);
    writeFileSync(paths, source);

    // A Nix installation is updated by its flake/profile owner. Never launch
    // npm/bun global installs from `omo update` and create a second installation.
    const update = root + '/bin/lib/self-update.js';
    source = readFileSync(update, 'utf8');
    const entry = 'export async function runSelfUpdate(args, options = {}) {';
    if (source.split(entry).length !== 2) throw new Error('omo self-update entry changed');
    source = source.replace(entry, entry + '\n  console.log("omo is managed by Nix; update the senpi-flake input or your Nix profile and rebuild.");\n  return 0;');
    writeFileSync(update, source);
    JS

    test "$(cat "$packageDir/node_modules/@code-yeongyu/senpi/.omo-engine-prepared")" = '${pin.version}'
  '';

  postFixup = ''
    rm $out/bin/omo
    makeWrapper ${nodejs_24}/bin/node $out/bin/omo \
      --add-flags "'$out/lib/node_modules/omo-ai/bin/omo.js'" \
      --prefix PATH : ${
        lib.makeBinPath ([ nodejs_24 ] ++ lib.optional (comment-checker != null) comment-checker)
      } \
      --set-default OMO_RUNTIME node
  '';

  # Plugin helper scripts run on the user's machine and retain portable shebangs.
  dontPatchShebangs = true;

  passthru.senpiVersion = pin.senpiVersion;
  meta = {
    description = "OmO Native coding agent with its pinned senpi engine and bundled plugin";
    homepage = "https://github.com/code-yeongyu/oh-my-openagent";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    mainProgram = "omo";
  };
}
