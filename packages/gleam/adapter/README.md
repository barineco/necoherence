# Necoherence (Gleam)

[プロジェクトの概要](../../../README.md)

このパッケージは、Necoherence の Gleam 実装です。

- Gleam 1.17 以降
- Erlang ターゲット対応

動作確認は OTP および Gleam ( CI 環境のバージョン ) で行っています。

## 検証結果

値の検証結果は、「確定」「残余」「停止」「失敗」に分類されます。分類の判定順序については [docs/terminology.md](../../../docs/terminology.md#確定残余停止失敗) を参照してください。本実装では、次の関数で結果を分類します。

- `semantic_types.classify_dispositions`: 指定された理由リストを分類する純粋関数

## データモデル宣言

仕様と照合の条件については、[docs/data-model.md](../../../docs/data-model.md) を参照してください。

呼び出し元は、信頼できる文字列、期待する参照識別子、出典を照合した上で、ライブラリをデコードして検証します。値を検証するには、照合済みのライブラリを `validate_value` に渡します。

- `decode_library`: ライブラリのデコードと検証
- `check_library`: ライブラリが満たすべき不変条件の検証
- `AdmittedLibrary`: 照合・受け入れ済みのライブラリ型
- `validate_value`: 値の検証

```gleam
import gleam/bit_array
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures

pub fn decide(expected, sources, trusted, input, library_wire, value) {
  let assert True = trusted == input
  let assert Ok(input_text) = bit_array.to_string(input)
  let assert Ok(profile_json) = values.parse_wire(input_text)
  let assert Ok(profile) = decode.decode_semantic_profile(profile_json)
  let assert True = profile.reference == expected
  let assert True = profile.source_refs == sources
  let assert Ok(library) = signatures.decode_library(library_wire)
  let assert True = signatures.library_graph(library).profile == profile
  signatures.validate_value(library, "unit", value)
}
```

主なエラー型とその要因:

- `ValueCodecFailure`: データモデル宣言の JSON デコード失敗
- `DecodeFailure`: データモデル宣言の構造デコード失敗
- `semantic_signatures.Failure`: ライブラリのデコードまたは検証失敗
- `LibraryCheckFailure`: ライブラリが宣言規則に違反している
- `semantic_generation_runtime.ValueFailure`: 値が型制約の検証で拒否された

## その他の機能

[プロジェクトの概要](../../../README.md) に記載の機能に加え、次の機能を提供します。

- 宣言の検証: 識別子の重複や未定義の型・定義への参照など、型や操作の宣言エラーを静的に検出
- 生成コード用ランタイム: 生成された Gleam コードが実行時に呼び出す、値検証およびコーデックの共通処理

ネットワーク副作用コマンドを HTTP 経由で実行する場合は、[`http/`](http/) の HTTP アダプターを使用します。

## 状態の型

状態を保持する型は不透明な型です。利用者は構築の関数で値を作り、読み取りの関数で内容を取り出します。構築の関数が入力を検査するので、各操作は構築済みの状態を受け取って検査を繰り返しません。

```text
core.World                                    構築: core.world
                                              読み取り: core.world_entries
request_progression.RequestProgressionSnapshot
                                              構築: request_progression.snapshot_of ( 失敗: DuplicateIdentity )
                                              読み取り: progression_policy, progression_budget,
                                                progression_current_identity, progression_entries,
                                                progression_revision, find_request
dynamic_admission.DynamicAdmissionState       構築: admission_state_of
                                              読み取り: admission_progression, admission_safety_limit,
                                                admission_provenance
network_effect.NetworkState                   構築: network_state_of ( 失敗: NetworkStateViolation )
                                              読み取り: network_attempts
                                              空の状態: empty_state
```

ネットワーク副作用のバイト列は `BitArray` で、長さが 8 ビットの倍数の値を受け付けます。それ以外の長さの値には、次の関数が `InvalidWireInstruction` を返します。

```text
network_effect.prepare, network_effect.retry
```

## 型付きの遷移モデル

ソルバーが探索対象とする型付き遷移モデルは、モジュール `typed_mapping` で定義されています。モデル定義とソルバーの探索結果については [docs/typed-transition-model.md](../../../docs/typed-transition-model.md) を参照してください。

## 残余の書き出し

モジュール `necoherence/semantic_residual_record` は、残余の記録に関する関数を提供します。その中の `encode_semantic_residual` は、値の検証が返した残余を、`neco-quotient` の正規のバイト列として書き出します。入力は、生成の `basis`、型の参照、値、義務の列であり、出力はバイト列または失敗です。

記録は次の 4 つのフィールドを持ちます。

- `schema`: 記録のバージョンを示す定数の文字列
- `basis`: 生成の `basis` の通信形式
- `input`: 型の参照と値の通信形式
- `residuals`: 義務の通信形式の列

各フィールドは既存の宣言の通信形式と同じ形で書かれ、整数は文字列、値はタグ付きのレコードになります。義務の列は `normalize_residuals` で正規化されるため、順序と重複によらず同じバイト列になります。また、`neco-quotient` の符号化の失敗は `Encoding` として保たれます。

## 型の包含とリソースの証拠の検証

実行時には、型の包含の判定と、ソルバーが返したリソースの証拠の検証を Gleam で行えます。

| 用途 | 関数 | モジュール |
|---|---|---|
| 型の包含の判定 | `check_assignable` | `necoherence/inclusion` |
| 包含の証明データの検証 | `verify_inclusion` | `necoherence/inclusion` |
| 反例の検証 | `verify_counterexample` | `necoherence/inclusion` |
| 到達の証拠の検証 | `verify_reachability_witness` | `necoherence/resource_witness` |
| 閉包の証拠の検証 | `verify_closure_witness` | `necoherence/resource_witness` |
| 非循環の証拠の検証 | `verify_acyclic_witness` | `necoherence/resource_witness` |
| 到達の証拠の復号 | `decode_reachability_witness` | `necoherence/semantic_generation_decode` |
| 閉包の証拠の復号 | `decode_closure_witness` | `necoherence/semantic_generation_decode` |
| 非循環の証拠の復号 | `decode_acyclic_witness` | `necoherence/semantic_generation_decode` |

関数 `check_assignable` の戻り値は `CompatibilityDecision` で、次の 3 つの場合があります。

- `Compatible`: 包含の証明データを持つ
- `Incompatible`: 反例の証明データ ( `CounterexampleCertificate` ) を持つ
- `CompatibilityUnknown`: 未解決の義務の一覧を持つ

検証に成功した時の戻り値は次のとおりです。

- `verify_inclusion`: `CheckedInclusion`
- `verify_counterexample`: `CheckedCounterexample`
- `verify_reachability_witness`: `CheckedReachability`
- `verify_closure_witness`: `CheckedClosure`
- `verify_acyclic_witness`: `CheckedAcyclic`

検証の規則は [docs/composition.md](../../../docs/composition.md#合成の検証) を参照してください。

## コード生成の受け入れ

形式 `ncoh-checked-generation@5` の JSON を受け入れる関数:

- `basis` の計算: `necoherence/semantic_signatures.generation_basis`
- 受け入れ検証: `necoherence/semantic_signatures.admit_generation`

生成識別値 `basis` と受け入れ検証の規則は [docs/generation.md](../../../docs/generation.md) を参照してください。

## 合成の実行

検証を通過した合成を実行する関数:

- 実行の開始: `necoherence/semantic_generation_runtime.start_composition`
- 実行の再開: `necoherence/semantic_generation_runtime.resume`

実行の開始には `CheckedComposition` を渡します。これは受け入れ検証の結果 ( `CheckedGeneration` ) から `semantic_signatures.checked_composition` で取得します。

実行の入力、関数の実装、進捗状態の意味は [docs/composition.md](../../../docs/composition.md#合成の実行) を参照してください。

## 付属のツール

型と操作の宣言から Gleam の型定義とコーデックを生成するコード生成ツール、および到達可能状態を探索するソルバーは、それぞれ次のディレクトリにあります。

- [`generator/`](../../../generator/)
- [`solver/`](../../../solver/)

これらの付属ツールのライセンスは AGPL-3.0-only です。

## 生成コードの初期化

本パッケージは、生成アーティファクトの整合性を検証する関数を提供します。

```gleam
semantic_signatures.generation_requirement(checked: CheckedGeneration) -> GenerationRequirement
```

関数 `generation_requirement` は、検証済みの生成アーティファクトから 10 項目で構成される型付き生成要件を抽出します。

生成されたモジュールの `initialize` は、検証済み生成値から `Context` を構築する初期化関数です。

```gleam
initialize(checked: CheckedGeneration) -> Result(Context, GenerationBasisMismatch)
```

初期化関数が返すコンテキスト型 `Context` は、照合済みの生成値を保持し、生成された値、コーデック、操作関数へ渡す共通入力として機能します。

## インストール

```bash
gleam add necoherence
```

## 開発時

次のコマンドでフォーマット検査、ビルド、テストを実行できます。

```bash
gleam format --check
gleam build --warnings-as-errors
gleam test
```

## ライセンス

[MIT](LICENSE)
