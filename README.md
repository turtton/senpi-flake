# senpi-flake

Nix flake for [code-yeongyu/senpi](https://github.com/code-yeongyu/senpi) — a coding agent CLI.

npm registry に公開されている `@code-yeongyu/senpi` を [`buildNpmPackage`](https://nixos.org/manual/nixpkgs/stable/#javascript-buildNpmPackage) でパッケージ化します。実行には Node.js 24 を同梱しており、`senpi` ラッパーが自動で `PATH` を解決します。

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

公開されるバイナリ:

- `senpi` — 正式名
- `pi` — upstream 互換のためのエイリアス（`senpi` へのシンボリックリンク）

## Auto-update

`.github/workflows/update.yml` が毎日 cron で実行され、npm registry 上の `@code-yeongyu/senpi` の最新バージョンを検出すると以下を更新します:

- `hashes.json`（`version` / `sourceHash` / `npmDepsHash`）
- `package-lock.json`（最新 tarball から再生成）

そのうえで `nix flake check` と `nix build .#senpi` で検証し、`senpi --version` の出力が新バージョンと一致することを確認したうえで Pull Request を作成します。

ローカルで手動更新する場合:

```sh
./update.sh
nix build .#senpi
```

> 必要コマンド: `curl`, `jq`, `nix`, `nix-prefetch-url`, `npm`, `tar`。

## License

This flake (packaging code) is provided as-is.
The packaged `senpi` binary is distributed under its upstream license — see the
[senpi repository](https://github.com/code-yeongyu/senpi).
