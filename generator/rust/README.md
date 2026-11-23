# necoherence-generator

本パッケージは、入力の JSON に含まれる `basis` を期待値と照合し、コードを生成する crate です。

入力の JSON と期待する `basis` の形は [../README.md](../README.md) に記載されています。

## 導入

本ツールは Rust 1.88 以降で動作し、コマンド `necoherence-generate` は `cargo install` で導入します。

```sh
cargo install necoherence-generator
```

ライブラリとして使う場合は、`Cargo.toml` に依存を加えます。

```toml
[dependencies]
necoherence-generator = "0.3.0"
```

## 使用例

形式 `ncoh-checked-generation@5` の JSON から Python のコードを生成する例:

```bash
necoherence-generate --target python --expected expected-basis.json --input input.exchange.json --output generated.py
```

## オプション

| オプション | 説明 |
|---|---|
| `--target` | 生成先の言語 |
| `--expected` | 期待する識別値と観測関数族を持つ JSON ファイル |
| `--input` | `ncoh-checked-generation@5` の JSON ファイル |
| `--output` | 出力先のファイル |
| `--runtime` | TypeScript の生成で使う実行時パッケージ名。既定は `necoherence` |
| `--java-package` | Java の生成で必須。生成するクラスのパッケージ |
| `--java-class` | Java の生成で必須。生成するクラス名 |

オプション `--target` に指定できる言語:

- `rust`
- `python`
- `typescript`
- `java`
- `gleam`

## 結果

成功した場合は、`--output` のファイルを 1 つ作り、終了コード 0 で終わります。

失敗した場合は、標準エラー出力に JSON を一行書き、終了コード 1 で終わります。

たとえば Java の生成で `--java-package` を省いた場合の出力は次のとおりです。

```json
{"failure":{"kind":"request","reason":"java_package"},"result":"failed"}
```

## 主な API

- `renderer::render_signature_exchange_for`: 生成先、期待する `basis`、入力の JSON の文字列を受け取り、照合の後にコードの文字列を返す。失敗は `RenderFailure`
- `renderer::Target`: 生成先の言語
- `boundary_failure::generator_failure_value`: 失敗を JSON の値にする

## 検査

```sh
cd generator/rust
cargo test
```

## ライセンス

AGPL-3.0-only

生成したコードは MIT License で、先頭に著作権、ライセンス、生成元の表示が書き込まれます。
