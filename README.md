# senpi-flake

Nix flake for [code-yeongyu/senpi](https://github.com/code-yeongyu/senpi) — a coding agent CLI.

Packages the `@code-yeongyu/senpi` release published on the npm registry via
[`buildNpmPackage`](https://nixos.org/manual/nixpkgs/stable/#javascript-buildNpmPackage).
Node.js 24 is bundled and a `senpi` wrapper resolves `PATH` automatically.

日本語版 README は [README.ja.md](./README.ja.md) を参照してください。

## Supported systems

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

## Usage

### Run directly

```sh
nix run github:turtton/senpi-flake -- --version
```

### Install into a profile

```sh
nix profile install github:turtton/senpi-flake
```

### As a flake input

```nix
{
  inputs.senpi.url = "github:turtton/senpi-flake";

  outputs = { self, nixpkgs, senpi, ... }: {
    # As a package
    # packages.x86_64-linux.default = senpi.packages.x86_64-linux.default;

    # Or via the overlay
    # nixpkgs.overlays = [ senpi.overlays.default ];
  };
}
```

Binaries exposed:

- `senpi` — canonical name
- `pi` — upstream-compatible alias (symlink to `senpi`)

## Auto-update

`.github/workflows/update.yml` runs on a daily cron. When it detects a new
version of `@code-yeongyu/senpi` on the npm registry, it updates:

- `hashes.json` (`version` / `sourceHash` / `assetsSourceHash` / `npmDepsHash`)
- `package-lock.json` (regenerated from the latest tarball)

> The package is built from **dual sources**. The main bundle comes from the
> npm tarball (`sourceHash`). Because the npm tarball does **not** ship the
> static assets produced by upstream's `copy-assets` build script (theme JSON,
> PNGs, HTML templates, vendored JS), this flake additionally fetches the
> matching GitHub tag archive (`assetsSourceHash`) and injects those assets
> into `dist/` during `postPatch`.

The workflow then runs `nix flake check` and `nix build .#senpi`, verifies
`senpi --version` matches the new version, and opens a pull request.

To run the update locally:

```sh
./update.sh
nix build .#senpi
```

> Required tools: `curl`, `jq`, `nix`, `nix-prefetch-url`, `npm`, `tar`.

## License

This flake (the packaging code) is provided as-is.
The packaged `senpi` binary is distributed under its upstream license — see the
[senpi repository](https://github.com/code-yeongyu/senpi).
