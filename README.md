# senpi-flake

A Nix flake for [OmO Native](https://github.com/code-yeongyu/oh-my-openagent) and its [senpi](https://github.com/code-yeongyu/senpi) engine.

The default package is the published `omo-ai` npm release. It provides the `omo` launcher, its exact-pinned senpi engine, and the complete plugin payload in one package, matching upstream's normal OmO Native install. Standalone `senpi` is also available.

日本語版 README は [README.ja.md](./README.ja.md) を参照してください。

## Supported systems

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

OmO Native uses a nonfree license in nixpkgs, so set `NIXPKGS_ALLOW_UNFREE=1` and pass `--impure` when evaluating this flake.

## Usage

Run OmO Native:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix run --impure github:turtton/senpi-flake -- --version
```

Install it into a profile:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix profile install --impure github:turtton/senpi-flake
omo
```

OmO Native stores its agent configuration under `~/.omo/agent`. Run `omo setup` to migrate an existing OpenCode or other supported agent configuration, and `omo doctor` to inspect the installation.

To use senpi without OmO:

```sh
nix run github:turtton/senpi-flake#senpi -- --version
```

Packages exposed by the flake:

| Package | Contents |
|---|---|
| `default`, `omo-native` | Published OmO Native launcher, engine, and plugin |
| `senpi` | Standalone senpi CLI (`senpi`, `pi`) |
| `comment-checker` | Pinned prebuilt comment checker |
| `omo-cli` | Compatibility alias for `omo-native` |
| `omo-senpi` | Compatibility plugin path at `lib/omo-senpi` |

The overlay exposes the same names. Existing configurations that invoke `senpi` directly can continue to use `.#senpi`; new OmO installations should use `.#omo-native` or the default output.

## Updating

The daily [update workflow](.github/workflows/update.yml) reads the stable `omo-ai` release from npm and updates it together with the exact senpi version declared by that release. It records the tarball and npm dependency hashes in `omo-hashes.json` / `hashes.json`, regenerates both committed lockfiles, builds both packages, and opens a pull request.

To update locally:

```sh
NIXPKGS_ALLOW_UNFREE=1 ./update-omo.sh
./update.sh "$(jq -r '.senpiVersion' omo-hashes.json)"
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
```

The standalone senpi package still injects source assets from the matching GitHub tag when the npm tarball omits them.

## License

This flake contains packaging code. OmO Native and senpi retain their respective upstream licenses; see the [OmO repository](https://github.com/code-yeongyu/oh-my-openagent) and the [senpi repository](https://github.com/code-yeongyu/senpi).
