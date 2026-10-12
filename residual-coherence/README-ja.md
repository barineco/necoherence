# residual-coherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

residual-coherence は、残余の整合性 ( residual coherence ) を検証するパッケージです。
ここでいう残余は、解析データが到達できると宣言した点と、解析データから到達できると導ける点との差です。
このパッケージは解析データを検証し、その差を残余量として報告します。
残余量は、導いた点のうち宣言に含まれていない点について、測度への寄与量 ( `measure_contribution` ) を合計した値です。

解析データの型は `AnalysisInput` で、フィールドの一覧は [analysis-input.schema.json](schema/analysis-input.schema.json) にあります。
解析データに含まれるのは、次の 3 つです。

- 到達できるかを判定する点 ( 点ごとに寄与量を持つ )
- 分岐
- 到達できると宣言した点

分岐は、自身の領域にある点のうち、要求する型 ( `required_type` ) の値が分岐の列挙する値に含まれる点を、到達できる点として導きます。

ほかのツールが出力した正規化解析の構造 ( 形式 `normalized-analysis` ) は、`AnalysisInput` に変換できます。
Python のソース文字列から、解析データを取り出すこともできます。

## インストール

このパッケージは Python 3.12 以降で動き、実行時に使うのは標準ライブラリだけです。

リポジトリを取得してから、`residual-coherence` のディレクトリでパッケージをインストールします。

```sh
git clone https://github.com/barineco/necoherence
cd necoherence/residual-coherence
python -m pip install .
```

## コマンドライン

コマンドは `residual-coherence <コマンド>` の形で実行し、標準入力から JSON を 1 つ読み取ります。
成功すると、正準形の JSON ( キーと集合の要素を決まった順序に並べた形式 ) を標準出力に書いて、終了ステータス 0 で終わります。
入力の誤りなどで失敗した場合は、型付きの失敗を標準エラー出力に書いて、終了ステータス 1 で終わります。
型付きの失敗は、失敗の種類 `kind` と問題の位置 `path` に、必要に応じて詳細の文字列を加えた JSON オブジェクトです。
`path` の値は、`$.schema_version` のような JSON パスです。
コマンド `python-source` では、ソースファイルの中で見つかった失敗に限り、`path` にそのファイルのパスが入ります。

コマンドと処理は次のとおりです。

| コマンド | 処理 |
|---|---|
| `validate` | `AnalysisInput` を検証し、正準形で出力する |
| `report` | 宣言した点、導いた点、導いたが宣言されていない点それぞれの寄与量の合計を、宣言した量、導いた量、残余量として計算する |
| `reachability` | 各分岐の対象領域の点のうち、分岐が要求する型 ( `required_type` ) の値が、分岐の列挙する値に含まれるものを、到達できる点として導く |
| `verify` | `AnalysisInput` に対する 8 つの自己整合性の検査を実行する。入力から到達点の導出、報告、正準形の出力をやり直し、検査ごとに観測値と期待値を並べて出力する |
| `normalized-analysis` | 正規化解析の構造を検証し、検証した構造、各対応を分類した結果、変換した `AnalysisInput`、その報告を出力する |
| `typed-reachability` | 型付き到達可能性のデータを検証し、検証項目の結果、変換した `AnalysisInput` のダイジェスト、診断を出力する |
| `python-source` | Python のソースから解析データを取り出す ( 実験的 ) |

### 正規化解析

コマンド `normalized-analysis` は、形式が `normalized-analysis` の JSON オブジェクトであれば、どのツールが出力したものでも読み取ります。
オブジェクトの `schema_version` には、次の値を入れます。

```json
{"schema_version": {"name": "normalized-analysis", "major": "1"}}
```

`schema_version` 以外に持つメンバーは次のとおりで、いずれも必須です。

- `source_revision`: 空でない文字列
- `language`: 解析対象の言語。次のいずれかの小文字の JSON 文字列で表す
  - `python`
  - `gleam`
- 10 個の表 ( リレーション ) 。各表は行の配列
  - `declarations`
  - `types`
  - `values`
  - `operation_inputs`
  - `branches`
  - `control_flow`
  - `place_accesses`
  - `external_effects`
  - `source_spans`
  - `stage_correspondences`

表の間の参照がすべて既存の識別子を指すことを確かめてから、構造を変換します。同じ入力に対して、結果は常に同じです。

各行のフィールド ( たとえば `branch` や `digest` ) と、各対応の分類は、[normalized_analysis.py](https://github.com/barineco/necoherence/blob/publish/residual-coherence/src/residual_coherence/normalized_analysis.py) で定めています。

### Python ソースの解析

コマンド `python-source` は実験的な機能です。
入力は、`revision` と、パスから Python ソース文字列への対応 `sources` を持つオブジェクトです。
各ソースを構文木に変換して、次の構造を検出します。

- `FlagCartesianProduct`: `bool` と注釈した通常の引数を 2 個以上持つ関数。フラグの数に応じて、場合の組み合わせが増える
- `ReceiverHiding`: 第 1 引数の名前が次のいずれかである関数。入力の一部が暗黙に渡される
  - `self`
  - `cls`
- `AmbientRead`: モジュール直下で代入した名前を、引数として受け取らずに読む関数

`AmbientRead` で、モジュール直下の名前を定めるのは、`名前 = 値` の形の通常の代入だけです。
`名前: 型 = 値` のような型注釈付きの代入は、この検出の対象外です。

結果のオブジェクトは、次の 3 つのメンバーを持ちます。

- `source_revision`: リビジョンと、ソースのダイジェスト
- `input`: `AnalysisInput`
  - 宣言済みの基準の点 `p-baseline` を持つ
  - 検出した構造ごとの点を 1 つずつ持つ
- `source_evidence`: 結果を裏づけるソースの位置

検出した点は宣言に含まれないため、残余量に加わります。
この機能が扱うのは、上の 3 つの構造の検出と、次に挙げる型付きの失敗の報告です。

ソースが次のいずれかを含む場合は、解析の結果の代わりに型付きの失敗を返します。

- `DynamicImport`: `__import__` などの動的なインポートの呼び出し
- `Reflection`: リフレクションによる組み込み関数の呼び出し。たとえば次のもの
  - `getattr` ( 既定値が名前か定数である 3 引数の呼び出しを除く )
  - `setattr`
- `UndeclaredExternalOutput`: 次の組み込み関数のいずれかの呼び出し
  - `print`
  - `open`
- `UnannotatedAny`: 引数または変数への `Any` 注釈
- `UnclosedExpression`: 構文エラー、空のソース集合、`extract_paths` で読み込みに失敗したファイル

入力と実行の例は次のとおりです。

```sh
printf '%s\n' '{"revision":"example","sources":{"sample.py":"value: int = 1\n"}}' | residual-coherence python-source
```

### 型付き到達可能性

コマンド `typed-reachability` は、2 つのメンバーを持つ JSON オブジェクトを読み取ります。
メンバー `artifact` は型付き到達可能性のデータで、型と構築子の閉じた集合、分岐の領域、各点が表層、コア、ネイティブの 3 つの形でどう対応するかを含みます。
フィールドは [typed-reachability-artifact.schema.json](schema/typed-reachability-artifact.schema.json) に一覧があります。
データの `source_revision` には、空でない文字列のフィールドが 3 つあります。

- `repository`
- `revision`
- `tree_digest`

メンバー `provenance` は、SHA-256 のダイジェストを値に持つオブジェクトです。
キーの名前は任意です。
値は `sha256:` に小文字の 16 進数 64 桁が続く形式で、ちょうど 2 つ必要です。
値はそのまま出力に含まれます。

最小の入力例は、ソースツリーでは `examples/typed-reachability-minimal.json` にあります。
インストールしたパッケージでは、`residual_coherence/examples/typed-reachability-minimal.json` にあります。
ソースツリーからパッケージをインストールした後、ディレクトリ `residual-coherence` で次のコマンドを実行すると、検証結果が出力されます。
終了ステータスは 0 です。

```sh
residual-coherence typed-reachability < examples/typed-reachability-minimal.json
```

## JSON Schema

ディレクトリ `schema/` の JSON Schema は、4 つのコマンドの入力と出力を記述します。

- [analysis-input.schema.json](schema/analysis-input.schema.json): `AnalysisInput`。`validate` が読み取る
- [residual-coherence-report.schema.json](schema/residual-coherence-report.schema.json): `report` の出力
- [analysis-verification.schema.json](schema/analysis-verification.schema.json): `verify` の出力
- [typed-reachability-artifact.schema.json](schema/typed-reachability-artifact.schema.json): `typed-reachability` の入力のうち `artifact` メンバー
- [typed-reachability-verification.schema.json](schema/typed-reachability-verification.schema.json): `typed-reachability` の出力
- [reachability-diagnostic.schema.json](schema/reachability-diagnostic.schema.json): その出力のうち `diagnostic` メンバー

## Python API

主な関数は次のとおりです。

- `validate_analysis_input`: `AnalysisInput` を検証する
- `calculate_report`: 残余量の報告を計算する
- `reduce_normalized_analysis_structure`: 正規化解析の構造を `AnalysisInput` へ変換する
- `reduce_typed_reachability`: 型付き到達可能性のデータを `AnalysisInput` へ変換する
- `extract_sources`: Python のソース文字列から解析データを取り出す
- `extract_paths`: Python のソースファイルから解析データを取り出す

失敗を表す値は次のとおりです。

- `TypedFailure`: `AnalysisInput` の検証、エンコード、報告の計算、検証項目の実行で起きる失敗
- `CanonicalConsumerFailure`: 正規化解析のデコード、構造の検証、参照の整合の確認、表示で起きる失敗
- `ReachabilityReductionFailure`: 型付き到達可能性のデータの検証、変換、診断、検証項目の実行で起きる失敗
- `AnalysisFailure`: Python ソースの解析で起きる失敗

メソッド `as_dict()` は、各値をコマンドラインが JSON として出力する辞書に変換します。
その他の公開している名前は、パッケージの `__all__` に並んでいます。

## 開発

開発用の依存パッケージをインストールしてから、テスト、型検査、ビルドを実行します。

```sh
python3 -m pip install ".[dev]"
python3 -m pytest -q
python3 -m mypy src tests
python3 -m build
```

## ライセンス

ライセンスは、構成要素ごとに次のとおりです。

- 検証器のソースコードとテスト: [AGPL-3.0-only](LICENSE)
- 検証器とやり取りするデータの JSON Schema: [MIT](schema/LICENSE)

検証器に渡す入力と、検証器が出力した結果の利用条件は、入力の作成者が決めます。
