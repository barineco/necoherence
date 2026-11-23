# コード生成ツール

コード生成ツールは、型と操作の宣言を収めた JSON から、各言語の型定義、値のコーデック、操作のコードを単一ファイルに生成します。入力の JSON に合成が含まれる場合は、合成を実行するコードも生成します。生成に先立ち、JSON の `basis` が呼び出し元の期待値と一致することを照合で確認します。

## 実装

| ディレクトリ | 言語 | 生成先 |
|---|---|---|
| `generator/rust` | Rust | Rust, Python, TypeScript, Java, Gleam |
| `generator/lean` | Lean | Lean |

継続的インテグレーション ( CI ) では、同じ JSON を二つの実装に渡し、照合の結果が一致することを確かめます。

## 入力

入力は JSON 形式で表され、`schema` の値は `ncoh-checked-generation@5` です。

| フィールド | 内容 |
|---|---|
| `schema` | 形式の名前 |
| `basis` | 宣言の内容を識別する値 |
| `signatures` | 型の宣言の集まり |
| `composition` | 合成。無い場合は `null` |
| `entrypoints` | 生成する定義の名前と定義の組の列 |

これら以外のフィールドを持つ JSON は拒否されます。

## 期待する `basis`

呼び出し元は、生成に使ってよい宣言の内容を識別する値を、`basis` と同じ形の JSON 形式で指定します。

## 照合

入力の JSON の `basis` から証明書を、呼び出し元が指定した値から期待値を作り、`neco-quotient` の照合で比べます。照合の条件と失敗の形は [docs/generation.md](../docs/generation.md) に記載されています。

## 失敗時の出力

失敗した場合、標準エラー出力に JSON を一行書き、終了コード 1 で終わります。出力ファイルは作成されません。

失敗の種類:

- 引数: `request`
- JSON の復号: `decode`
- 照合: `certificate`
- 生成: `rendering`

## ライセンス

ツール自体は AGPL-3.0-only です。

生成されたコードには MIT License が適用され、先頭に著作権、ライセンス、生成元の表示が書き込まれます。表示の内容と再利用の条件は [docs/generation.md](../docs/generation.md#出力) を参照してください。

## 使い方

言語ごとの CLI とライブラリについて、Rust の実装は [rust/README.md](rust/README.md) を参照してください。

また、Lean の実装を使う場合は、`generator/lean` のディレクトリで次のコマンドを実行します。

```bash
lake build semantic_generation
lake exe semantic_generation input.exchange.json expected-basis.json generated.lean
```
