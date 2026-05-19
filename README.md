# senpi-flake

Nix flake for [code-yeongyu/senpi](https://github.com/code-yeongyu/senpi) — a coding agent CLI.

GitHub Releases に公開されている prebuilt バイナリをそのままパッケージ化します（ビルドは行いません）。
Linux では `autoPatchelfHook` で動的リンカを Nix store に解決します。

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

`.github/workflows/update.yml` が毎日 cron で実行され、`code-yeongyu/senpi` の最新リリースを検出すると
`package.nix` の `version` と各プラットフォームの SRI ハッシュを更新し、`nix flake check` と
`nix build .#senpi` で検証したうえで Pull Request を作成します。

ローカルで手動更新する場合:

```sh
./update.sh
nix build .#senpi
```

## License

This flake (packaging code) is provided as-is.
The packaged `senpi` binary is distributed under its upstream license — see the
[senpi repository](https://github.com/code-yeongyu/senpi).
