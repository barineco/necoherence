# Necoherence

本基盤 ( Necoherence ) は、型シグネチャを持つ操作の宣言と実行を担い、データモデル宣言に基づいて値の妥当性を検証します。

## 機能

リソースの状態は、値とリビジョン ( 更新番号 ) の組で表します。

- `Core`: 観測したリビジョンに基づくリソースの更新と、失敗要因の分類
- `Call`: 宣言された操作の実行と、その結果の観測
- `Iteration`: 上限回数を指定した反復処理 ( fold, recurse, closure )
- `Store`: リソースごとの値とリビジョンの記録
- `Record`: 実行した操作の記録 ( 宣言、入力、結果 )
- `Reconcile`: 操作の記録と、現在のリソース状態との照合
- `Request progression`: リクエストの開始から完了までの追跡
- `Dynamic admission`: 処理能力の余力に基づくリクエスト開始判定
- `Step transition`: 入力 1 件ごとの状態遷移
- `File effect`: ファイル操作と、その結果の観測
- `Network effect`: HTTP リクエストの試行、実行ホストでの観測、再試行の制御

各機能は、入力に対して結果または明示的な失敗を返します。

## 付属ツール

- [コード生成ツール](generator/): 型と操作の宣言から、ターゲット言語ごとの型定義と直列化コーデックを生成
- [ソルバー](solver/): 型付き遷移モデルを探索し、目標状態への到達可能性やデッドロックの有無を判定して証拠を返却
- [検証ツール ( residual-coherence )](residual-coherence/): プログラムの分岐条件と到達可能点の宣言を照合し、宣言外の残余点を算出

## 各言語の実装

以下の 6 言語で実装を提供しています。

- [Lean](packages/lean/)
- [Python](packages/python/adapter/): Python 3.14 以降に対応
- [Rust](packages/rust/adapter/)
- [TypeScript](packages/typescript/adapter/)
- [Java](packages/java/adapter/): Java 21 に対応
- [Gleam](packages/gleam/adapter/): Erlang ターゲットに対応

基準となる Lean の実装は実行可能な仕様であり、他の 5 言語の実装は、同じ入力に対する Lean の出力と突き合わせて検証しています。各コアパッケージはネットワーク副作用の状態を記録・更新し、実通信を担う呼び出し元から渡されたポート経由で観測結果を受け取る設計です。

ネットワーク通信で HTTP リクエストを実行する場合は、各言語向けに用意された独立したアダプターパッケージを使います。

- [Rust の HTTP アダプター](packages/rust/adapter/http/)
- [Python の HTTP アダプター](packages/python/adapter/http/)
- [TypeScript の HTTP アダプター](packages/typescript/adapter/http/)
- [Java の HTTP アダプター](packages/java/adapter/http/)
- [Gleam の HTTP アダプター](packages/gleam/adapter/http/)

## 文書

- [構成と証明](docs/construction-as-proof.md): 実行結果を構成的証明として解釈する方法
- [合成](docs/composition.md): 合成の探索の結果、合成の検証、合成の実行
- [型付きの遷移モデル](docs/typed-transition-model.md): ソルバーが探索するモデルと探索結果
- [データモデル宣言](docs/data-model.md): 宣言する内容と照合の規則
- [コード生成](docs/generation.md): 入力の形式、`basis` の照合、受け入れ検証、出力
- [機能](docs/operations.md): 機能族と操作、ネットワーク副作用の指示と観測、言語間の一致
- [用語索引](docs/terminology.md): 主要な用語の定義と説明
- [Lean の定義と定理](docs/lean.md): 検証済みの型と、その意味論を保証する定理

## ライセンス

- 各言語の実装: [MIT License](LICENSE)
- [コード生成ツール](generator/): [AGPL-3.0-only](generator/LICENSE)
- [ソルバー](solver/): [AGPL-3.0-only](solver/rust/LICENSE)
- [検証ツール ( residual-coherence )](residual-coherence/): [AGPL-3.0-only](residual-coherence/LICENSE)
- 検証ツールとやり取りするデータの JSON Schema: [MIT License](residual-coherence/schema/LICENSE)

コード生成ツールの出力コードおよびソルバーの証拠 ( witness ) には、利用しやすい MIT License が適用されます。出力コードの先頭には著作権、ライセンス、生成元の表示が入り、この表示を残せば、生成したコードを利用者のプロジェクトのライセンスのもとで改変し、再配布し、別の用途に利用できます。

ファイルごとのライセンスは、各ファイルの先頭にある SPDX 宣言または [REUSE.toml](REUSE.toml) で確認できます。
