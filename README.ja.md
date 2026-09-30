# senpi-flake

[OmO Native](https://github.com/code-yeongyu/oh-my-openagent) と、そのエンジンである [senpi](https://github.com/code-yeongyu/senpi) の Nix flake です。

既定パッケージは npm 公開版の `omo-ai` です。公式の通常インストールと同じく、`omo` ランチャー、バージョンが固定された senpi、プラグイン一式をまとめて提供します。senpi 単体も利用できます。

English README: [README.md](./README.md).

## 対応システム

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-darwin`
- `aarch64-darwin`

OmO Native は nixpkgs では unfree ライセンス扱いのため、flake の評価時に `NIXPKGS_ALLOW_UNFREE=1` と `--impure` が必要です。

## 使い方

OmO Native を直接実行:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix run --impure github:turtton/senpi-flake -- --version
```

プロファイルにインストール:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix profile install --impure github:turtton/senpi-flake
omo
```

設定は `~/.omo/agent` に保存されます。既存の OpenCode などから移行する場合は `omo setup`、導入状況の確認には `omo doctor` を使用します。

OmO を使わず senpi 単体を実行する場合:

```sh
nix run github:turtton/senpi-flake#senpi -- --version
```

公開パッケージ:

| パッケージ | 内容 |
|---|---|
| `default`, `omo-native` | npm 公開版 OmO Native のランチャー・エンジン・プラグイン |
| `senpi` | senpi 単体の CLI（`senpi`、`pi`） |
| `comment-checker` | バージョン固定のビルド済みバイナリ |
| `omo-cli` | `omo-native` の互換エイリアス |
| `omo-senpi` | `lib/omo-senpi` に配置した互換プラグイン |

overlay も同じ名前を公開します。既存の senpi 単体利用は `.#senpi` を使い、新たな OmO 導入には既定出力または `.#omo-native` を使用してください。

## 更新

毎日の [更新ワークフロー](.github/workflows/update.yml) は npm の安定版 `omo-ai` を取得し、そのパッケージが正確に指定する senpi バージョンと一緒に更新します。tarball と npm 依存関係のハッシュを `omo-hashes.json` / `hashes.json` に保存し、両方の lockfile を再生成してビルドを検証した後、Pull Request を作成します。

手動更新:

```sh
NIXPKGS_ALLOW_UNFREE=1 ./update-omo.sh
./update.sh "$(jq -r '.senpiVersion' omo-hashes.json)"
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
```

senpi 単体パッケージでは、npm tarball に欠けている静的アセットを対応する GitHub タグから補います。

## ライセンス

この flake はパッケージング用コードです。OmO Native と senpi にはそれぞれ upstream のライセンスが適用されます。詳細は [OmO](https://github.com/code-yeongyu/oh-my-openagent) と [senpi](https://github.com/code-yeongyu/senpi) のリポジトリを参照してください。
