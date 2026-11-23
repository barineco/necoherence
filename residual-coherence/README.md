# residual-coherence

[プロジェクトの概要](../README.md)

パッケージ `residual-coherence` は、残余の整合性 ( residual coherence ) を検証する Python パッケージです。解析対象プログラムを入力値から出力値を計算する関数合成としてモデル化し、分岐条件の評価を経て到達可能な状態点を有限データ空間上で追跡・検証します。入力は有限個の離散点から成る集合として表現され、各点が型ごとの座標値を持ちます。各分岐には評価対象の点集合である領域、要求型、および許容値の一覧が定義されており、領域内の点のうち該当型の座標値が一覧に含まれるものが分岐を通過して到達可能と判定されます。

## 残余と解析モデル

残余 ( residual ) とは、「解析データから論理的に到達可能と導出できる点」から「解析データ内で到達可能と事前宣言された点」を除いた差分の点集合です。本パッケージは解析データを検証し、各残余点が持つ測度への寄与量 ( `measure_contribution` ) の総和を残余量として算出・報告します。

検証に用いる解析データの型は `AnalysisInput` であり、そのスキーマ定義は [`analysis-input.schema.json`](schema/analysis-input.schema.json) で定めています。

解析データの主な構成要素:

- 入力点集合 ( 各点に寄与量が定義される )
- 分岐条件の定義
- 到達可能と事前宣言された点集合

外部ツールが出力する `normalized-analysis` 形式のデータ構造を検証して `AnalysisInput` へ変換する処理や、Python ソースコードから解析データを静的に抽出する処理も利用できます。

## インストール

動作には Python 3.12 以降が必要であり、実行時の依存関係は標準ライブラリのみです。

リポジトリを取得後、`residual-coherence` ディレクトリでインストールします。

```sh
git clone https://github.com/barineco/necoherence
cd necoherence/residual-coherence
python -m pip install .
```

## コマンドライン

コマンド `residual-coherence <コマンド>` を実行すると、標準入力から 1 件の JSON を受け取って処理します。処理が正常終了した場合は、キーや集合要素を決定的な順序で整列した正準形 JSON を標準出力へ書き出して終了ステータス 0 を返します。

入力不正などの理由で処理が失敗した場合は、エラー種別、問題箇所の JSON パス、詳細メッセージからなる型付きエラー情報を標準エラー出力へ JSON 形式で出力し、終了ステータス 1 を返します。

提供コマンド一覧:

| コマンド | 処理内容 |
|---|---|
| `validate` | `AnalysisInput` の妥当性を検証し、正準形の JSON 形式で出力 |
| `report` | 宣言点、導出点、未宣言の導出点 ( 残余 ) それぞれの寄与量総和を計算・出力 |
| `reachability` | 各分岐の対象領域点のうち、要求型 ( `required_type` ) の値が分岐許容値に含まれる点を到達可能点として導出 |
| `verify` | `AnalysisInput` に対する 8 種類の自己整合性検証を実行し、検証結果の観測値と期待値を出力 |
| `normalized-analysis` | 正規化解析のデータ構造の妥当性を検証し、`AnalysisInput` への変換およびレポートを出力 |
| `typed-reachability` | 型付き到達可能性データを検証し、検証結果および変換後ハッシュ値を出力 |
| `python-source` | Python ソースコードから解析データを静的抽出 ( 実験的機能 ) |

### 正規化解析

コマンド `normalized-analysis` は、スキーマ形式が `normalized-analysis` である JSON オブジェクトを読み取ります。

オブジェクトの `schema_version` には次の値を指定します。

```json
{"schema_version": {"name": "normalized-analysis", "major": "1"}}
```

必須フィールド:

- `source_revision`: 空でない文字列
- `language`: 解析対象言語。次のいずれか
  - `"python"`
  - `"gleam"`
- 10 種類のリレーションテーブル ( 行オブジェクトの配列 )
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

各テーブル間の外部キー参照がすべて実在する識別子を指していることを検証した上で、内部データ構造へ変換します。

### Python ソースの解析

実験的コマンド `python-source` は、Python ソースコードをパースして AST から以下の構造パターンを静的に検出します。

- `FlagCartesianProduct`: `bool` 型として注釈された引数を 2 個以上持つ関数 ( フラグ組み合わせによる状態爆発 )
- `ReceiverHiding`: 第 1 引数名が次のいずれかである関数 ( 暗黙のレシーバ注入 )
  - `self`
  - `cls`
- `AmbientRead`: モジュール直下で代入された変数を暗黙的に参照する関数
  - 対象の形式: `名前 = 値`
  - 対象外の形式 ( 型注釈付き ): `名前: 型 = 値`

ソースコードに次の要素が含まれる場合は、型付きエラーを返して解析を拒否する仕様です。

- 動的インポート: `__import__` や `import_module`
- リフレクション: 動的な `getattr` や各種の属性操作関数 ( `setattr` など )
- 未宣言の外部出力: `print` や `open`
- 型注釈: `Any`

### 型付き到達可能性

- `artifact`: 型付き到達可能性データ
- `provenance`: 2 件の `sha256:` ダイジェスト ( 64 桁の小文字 16 進数 ) を持つ JSON オブジェクト

テスト実行例:

```sh
residual-coherence typed-reachability < python/examples/typed-reachability-minimal.json
```

## JSON Schema

ディレクトリ `schema/` 配下に、各コマンドの入出力スキーマ定義を収録しています。

- [analysis-input.schema.json](schema/analysis-input.schema.json): `AnalysisInput` スキーマ
- [residual-coherence-report.schema.json](schema/residual-coherence-report.schema.json): `report` 出力スキーマ
- [analysis-verification.schema.json](schema/analysis-verification.schema.json): `verify` 出力スキーマ
- [typed-reachability-artifact.schema.json](schema/typed-reachability-artifact.schema.json): `typed-reachability` 入力スキーマ
- [typed-reachability-verification.schema.json](schema/typed-reachability-verification.schema.json): `typed-reachability` 出力スキーマ
- [reachability-diagnostic.schema.json](schema/reachability-diagnostic.schema.json): 診断情報スキーマ

## Python API

主要な公開関数:

- `validate_analysis_input`: `AnalysisInput` の妥当性を検証
- `calculate_report`: 残余量レポートを計算
- `reduce_normalized_analysis_structure`: 正規化解析のデータ構造を `AnalysisInput` へ変換
- `reduce_typed_reachability`: 型付き到達可能性データを `AnalysisInput` へ変換
- `extract_sources`: Python ソース文字列から解析データを抽出
- `extract_paths`: Python ソースファイルから解析データを抽出

主要なエラー型:

- `TypedFailure`: `AnalysisInput` の検証・レポート計算で発生するエラー
- `CanonicalConsumerFailure`: 正規化解析のデコード・参照整合性の検証で発生するエラー
- `ReachabilityReductionFailure`: 型付き到達可能性データの検証・変換で発生するエラー
- `AnalysisFailure`: Python ソースコードの静的解析で発生するエラー

各エラー型の `as_dict()` メソッドで、CLI 出力と同等の JSON 辞書表現を取得できます。

## 開発

```sh
python3 -m pip install ".[dev]"
python3 -m pytest -q
python3 -m mypy python/src python/tests
python3 -m build
```

## ライセンス

構成要素ごとのライセンス:

- 検証ツールのソースコードおよびテスト: [AGPL-3.0-only](LICENSE)
- 入出力データ定義の JSON Schema: [MIT License](schema/LICENSE)
