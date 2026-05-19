# senpi-flake

[code-yeongyu/senpi](https://github.com/code-yeongyu/senpi) のコーディングエージェント CLI 向け Nix flake です。

npm registry に公開されている `@code-yeongyu/senpi` を [`buildNpmPackage`](https://nixos.org/manual/nixpkgs/stable/#javascript-buildNpmPackage) でパッケージ化します。実行には Node.js 24 を同梱しており、`senpi` ラッパーが自動で `PATH` を解決します。

English README: see [README.md](./README.md).

## 対応システム

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

## 使い方

### 直接実行

```sh
nix run github:turtton/senpi-flake -- --version
```

### プロファイルにインストール

```sh
nix profile install github:turtton/senpi-flake
```

### flake input として利用

```nix
{
  inputs.senpi.url = "github:turtton/senpi-flake";

  outputs = { self, nixpkgs, senpi, ... }: {
    # パッケージとして
    # packages.x86_64-linux.default = senpi.packages.x86_64-linux.default;

    # あるいは overlay 経由
    # nixpkgs.overlays = [ senpi.overlays.default ];
  };
}
```

公開されるバイナリ:

- `senpi` — 正式名
- `pi` — upstream 互換のためのエイリアス（`senpi` へのシンボリックリンク）

## 自動アップデート

`.github/workflows/update.yml` が毎日 cron で実行され、npm registry 上の `@code-yeongyu/senpi` の最新バージョンを検出すると以下を更新します:

- `hashes.json`（`version` / `sourceHash` / `assetsSourceHash` / `npmDepsHash`）
- `package-lock.json`（最新 tarball から再生成）

> パッケージは **dual-source** 構成です。本体は npm tarball（`sourceHash`）由来ですが、upstream の `copy-assets` ビルドスクリプトが生成する静的アセット（テーマ JSON / PNG / HTML テンプレート / vendored JS）が npm tarball に含まれません。そのため、同じバージョンの GitHub tag アーカイブ（`assetsSourceHash`）からそれらを取り出し、`postPatch` で `dist/` に注入しています。

そのうえで `nix flake check` と `nix build .#senpi` で検証し、`senpi --version` の出力が新バージョンと一致することを確認したうえで Pull Request を作成します。

ローカルで手動更新する場合:

```sh
./update.sh
nix build .#senpi
```

> 必要コマンド: `curl`, `jq`, `nix`, `nix-prefetch-url`, `npm`, `tar`。

## ライセンス

この flake（パッケージング用コード）は as-is で提供されます。
パッケージ化される `senpi` バイナリ自体は upstream のライセンスに従います — 詳細は [senpi リポジトリ](https://github.com/code-yeongyu/senpi) を参照してください。
