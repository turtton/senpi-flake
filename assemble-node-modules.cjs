#!/usr/bin/env node
// Assemble a bun.lock-shaped node_modules tree from individually fetched npm
// tarballs.  Invoked by omo-common.nix's bunDeps buildPhase as:
//
//   node assemble-node-modules.cjs <omo-npm-packages.json> <pkg-mapping.json>
//
// omo-npm-packages.json comes from generate-npm-packages.py (bun.lock parsed
// into npmPackages / workspaceSymlinks / filePackages); pkg-mapping.json maps
// each npmPackages key to its fetchurl store path.  The layout produced here
// must stay compatible with what `bun install` created for the old FOD, since
// omo-senpi.nix and omo-cli.nix copy this tree next to the checkout and rely
// on workspace-relative symlinks and node_modules/.bin.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const [, , pkgDataPath, pkgMapPath] = process.argv;
if (!pkgDataPath || !pkgMapPath) {
  console.error("usage: assemble-node-modules.cjs <pkg-data.json> <pkg-map.json>");
  process.exit(1);
}

const pkgData = JSON.parse(fs.readFileSync(pkgDataPath, "utf8"));
const pkgMap = JSON.parse(fs.readFileSync(pkgMapPath, "utf8"));

const npmPkgs = pkgData.npmPackages || {};
const wsSymlinks = pkgData.workspaceSymlinks || {};
const filePkgs = pkgData.filePackages || {};

// Entries nested under a file: package's installPath (e.g. typescript keyed
// under @code-yeongyu/lsp-daemon) must NOT be materialized here: the file:
// link target is the real in-tree source directory, whose own dependency
// manager (packages/lsp-daemon's npm ci via fetchNpmDeps) already provides
// them.  Unpacking them would also create a real directory where the file:
// symlink needs to go.  bun's own layout isolates these inside its .bun
// store; the direct layout used here gets the same resolution through the
// linked source tree instead.
const fileRoots = Object.values(filePkgs).map((info) => `${info.installPath}/`);
const underFileRoot = (installPath) => fileRoots.some((root) => installPath.startsWith(root));

function linkRelative(installPath, sourcePath) {
  const installDir = path.dirname(installPath);
  fs.mkdirSync(installDir, { recursive: true });
  const relTarget = path.relative(installDir, sourcePath);
  try {
    fs.unlinkSync(installPath);
  } catch {
    // nothing to replace
  }
  fs.symlinkSync(relTarget, installPath);
}

// The node_modules directory directly containing installPath
// ("packages/x/node_modules/dep" -> "packages/x/node_modules").
function modulesRootOf(installPath) {
  const marker = "node_modules/";
  const at = installPath.lastIndexOf(marker);
  if (at === -1) throw new Error(`installPath outside node_modules: ${installPath}`);
  return installPath.slice(0, at + marker.length).replace(/\/$/, "");
}

function binEntriesOf(info) {
  // npm's bin field is either an object {name: relpath} or, for single-bin
  // packages, a bare string (name is then the unscoped package name).
  if (!info.bin) return [];
  if (typeof info.bin === "string") {
    return [[path.basename(info.installPath), info.bin]];
  }
  return Object.entries(info.bin);
}

let unpacked = 0;
let symlinked = 0;
let binLinked = 0;
let skippedNested = 0;

for (const [key, info] of Object.entries(npmPkgs)) {
  if (underFileRoot(info.installPath)) {
    skippedNested++;
    continue;
  }

  const storePath = pkgMap[key];
  if (!storePath) {
    console.error(`ERROR: no fetched tarball mapped for ${key}`);
    process.exit(1);
  }

  fs.mkdirSync(info.installPath, { recursive: true });
  // npm tarballs wrap everything in a top-level package/ directory.
  execFileSync("tar", ["xzf", storePath, "--strip-components=1", "-C", info.installPath], {
    stdio: "inherit",
  });
  unpacked++;

  for (const [binName, binRel] of binEntriesOf(info)) {
    const binDir = path.join(modulesRootOf(info.installPath), ".bin");
    fs.mkdirSync(binDir, { recursive: true });
    linkRelative(path.join(binDir, binName), path.join(info.installPath, binRel));
    binLinked++;
  }
}

// workspace:* and file: deps link into the source tree; the links dangle
// inside this derivation and only resolve once the tree sits next to the
// checkout (dontCheckForBrokenSymlinks in omo-common.nix covers this).
// Links nested under another file: package are skipped for the same reason
// as nested npm packages above.
for (const info of [...Object.values(wsSymlinks), ...Object.values(filePkgs)]) {
  if (underFileRoot(info.installPath)) {
    skippedNested++;
    continue;
  }
  linkRelative(info.installPath, info.sourcePath);
  symlinked++;
}

console.log(
  `assembled node_modules: ${unpacked} tarballs unpacked, ${symlinked} workspace/file links, ${binLinked} .bin entries, ${skippedNested} nested file:-dep entries skipped`,
);
