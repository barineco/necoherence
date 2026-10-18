# Necoherence

[English](README.md)

Necoherence は、型シグニチャと値の意味を扱うためのライブラリです。

## 機能

Necoherence では、操作を入力と結果の型とともに宣言し、宣言した操作を実行します。
状態は、リソースごとに、値とリビジョン ( 版の番号 ) の組で保持します。
どの機能も、Lean 4 で検証した定義をもとに実装しています。

- `Core`: 観測したリビジョンを前提にしたリソースの更新と、失敗の分類
- `Call`: 宣言した操作の実行と、その結果の観測
- `Iteration`: 回数に上限のある反復 ( fold、recurse、closure )
- `Store`: リソースごとの値とリビジョンの保持
- `Record`: 実行した操作の記録 ( 宣言、入力、結果 )
- `Reconcile`: 操作の記録と、現在のリソースの状態との照合
- `Request progression`: リクエストの開始から終了までの追跡
- `Dynamic admission`: 処理能力の余裕にもとづく、リクエストの開始の判定
- `Step transition`: 入力 1 件ごとの状態の遷移
- `File effect`: ファイルの操作と、その結果の観測
- `Network effect`: HTTP リクエストの試行、実行したホストでの観測、再試行の許可

どの操作も、入力に応じて、結果か明示的な失敗のいずれかを返します。

## 付属のツール

生成器とソルバーは [tools/](tools/) に、検証器は Python パッケージの [residual-coherence](residual-coherence/) にあります。

- 生成器: 型と操作の宣言から、各言語の型とコーデックを生成する
- ソルバー: 型付きの遷移モデルから、到達できる状態を探索する
- 検証器: 解析データに書かれた、到達できる点の宣言を検証する

## 各言語の実装

Necoherence は、次の 6 つの言語に向けて実装を提供しています。

- [Lean](lean/)
- [Python](python/): Python 3.12 以降に対応
- [Rust](rust/)
- [TypeScript](typescript/)
- [Java](java/): Java 21 に対応
- [Gleam](gleam/): Erlang ターゲットに対応

Lean の実装は、仕様を実行できる定義の形で書いたものです。他の 5 言語の実装については、結果を Lean の定義の結果と照合して検証しています。各実装の版は、いずれも `0.2.1` です。ビルドとテストの手順は、各ディレクトリの日本語の README に書いてあります。

HTTP の実行は任意です。
Rust では、feature の `http-adapter` で有効にします。
ほかの実行時の実装で HTTP を実行するのは、次の独立したアダプターのパッケージです。

- [Python の HTTP アダプター](python-http-adapter/)
- [TypeScript の HTTP アダプター](typescript-http-adapter/)
- [Java の HTTP アダプター](java-http-adapter/)
- [Gleam の HTTP アダプター](gleam-http-adapter/)

核のパッケージが持つのは、ネットワーク副作用の台帳と、呼び出し側が渡すポートを通して観測を受け取る仕組みです。

## 検証

検証の対象と方法は次のとおりです。

- ネットワーク副作用: Lean の実行ファイルと他の実装との結果の照合 ( [comparison/network_effect](https://github.com/barineco/necoherence/tree/publish/comparison/network_effect) )
- 型付きの遷移モデルのソルバー: 独立に書いた参照実装との照合 ( [comparison/typed_mapping_solver](https://github.com/barineco/necoherence/tree/publish/comparison/typed_mapping_solver) )
- 宣言とプリセット: 6 言語の間での意味の照合 ( [comparison/declaration](https://github.com/barineco/necoherence/tree/publish/comparison/declaration) )
- 再生成できるデータ: 原典から生成し直したファイルの照合 ( [presets/tools](https://github.com/barineco/necoherence/tree/publish/presets/tools) )
- 共通の操作: 6 言語の結果と失敗の種類の照合 ( [comparison/shared_operations](https://github.com/barineco/necoherence/tree/publish/comparison/shared_operations) )
- その他の機能: 各言語のテスト
- HTTP アダプター: ローカルのテスト用サーバーへ実際にリクエストを送るテスト

## 意味プロファイル

呼び出し側は、宣言を復号するときや、生成したライブラリを受け入れるときに、版の付いた意味プロファイルを渡します。意味プロファイルが定めるのは、次の 3 つです。

- 書式の規則と、値が取りうる範囲
- Unicode の書記素 ( grapheme ) のデータ
- JSON のオブジェクトを分類するラッパー、型のタグ、閉じた形 ( sealed form )

Necoherence は受け取ったプロファイルを検証し、値の検証、コードの生成、実行のすべてで同じプロファイルを使います。どのデータモデルを使うかを選ぶのは、呼び出し側です。

リポジトリには、AT Protocol のデータモデルがプリセットとして収録されています。6 つの実装はいずれも、リポジトリにある一つのプロファイルを共通に読み込みます。このため、各言語のパッケージは特定のデータモデルから独立して使えます。

- [presets/atproto-data-model/profile.json](presets/atproto-data-model/profile.json): プロファイル
- [presets/manifest.json](presets/manifest.json): 識別子、版、出典、SHA-256 のダイジェスト

## ライセンス

ライセンスは、構成要素ごとに次のとおりです。

- 各言語の実装: [MIT License](LICENSE)
- [生成器とソルバー](tools/): [AGPL-3.0-only](tools/LICENSE)
- [検証器 residual-coherence](residual-coherence/): AGPL-3.0-only
- 検証器とやり取りするデータの JSON Schema: [MIT License](residual-coherence/schema/LICENSE)

生成器が出力したコードと、ソルバーが返す証拠 ( witness ) は、MIT License のもとで利用できます。生成したコードの先頭の行にも、そのことが記されています。

ファイルごとのライセンスは、各ファイルの先頭にある SPDX の宣言か、[REUSE.toml](REUSE.toml) で確かめられます。
