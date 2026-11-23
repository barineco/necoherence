# Necoherence (Rust)

[プロジェクトの概要](../../../README.md)

このクレートは、Necoherence の Rust 実装です。

- Rust 1.88 以降

## データモデル宣言

仕様と照合の条件については、[docs/data-model.md](../../../docs/data-model.md) を参照してください。

データモデル宣言のデコード関数 `decode_value_profile` は UTF-8 文字列を入力として受け取ります。そのため呼び出し元では、あらかじめ信頼できるバイト列と入力バイト列の同一性を照合した上で文字列に変換し、期待する参照識別子や出典情報が一致しているかを確かめてから型ライブラリの検証へ進みます。

```rust
use necoherence::exact_json::JsonValue;
use necoherence::semantic_exchange::decode_value_profile;
use necoherence::semantic_types::{ProfileRef, SourceIdentity, SemanticEvaluation};
use necoherence::semantic_validation::{evaluate_value, FormatWorkspace, PreparedValidator};
use necoherence::signature_admission::check_type_signatures;
use necoherence::type_signatures::{check_library, TypeSignatureLibrary};

fn decide(
    expected: &ProfileRef, sources: &[SourceIdentity], trusted: &[u8], input: &[u8],
    mut library: TypeSignatureLibrary, type_id: &str, value: &JsonValue,
) -> Result<SemanticEvaluation, String> {
    if trusted != input { return Err("profile bytes differ".into()); }
    let text = std::str::from_utf8(input).map_err(|error| error.to_string())?;
    let profile = decode_value_profile(text).map_err(|error| error.to_string())?;
    if &profile.reference != expected || profile.source_refs != sources {
        return Err("profile basis differs".into());
    }
    library.profile = profile;
    check_library(&library).map_err(|error| format!("{error:?}"))?;
    let graph = check_type_signatures(&library).map_err(|error| error.to_string())?;
    let reference = &graph.nodes.iter()
        .find(|node| node.reference.definition_name.as_ref() == type_id)
        .ok_or("unknown type")?.reference;
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    Ok(evaluate_value(&mut validator, reference, value))
}
```

公開 API が返す主なエラー型および判定型:

- `GenerationFailure`: データモデル宣言のデコード失敗
- `LibraryCheckFailure`: 型・操作ライブラリの検証失敗
- `AdmissionFailure`: 型宣言グラフの構築・受け入れ失敗
- `SemanticEvaluation`: 入力の来歴情報を含む分類済み判定結果
- `ValueFailure`: 拒否された値に関する詳細情報

生成されたライブラリの照合に失敗した場合、関数 `necoherence::semantic_exchange::signature_generation_context` が失敗を返します。この失敗は `AdmissionFailure` を内包した `GenerationFailure` として保持されます。

## 値の検証

値の検証には次の関数を使用します。結果分類の判定順序については [docs/terminology.md](../../../docs/terminology.md#確定残余停止失敗) を参照してください。

- `evaluate_value`: 所有値の検証
- `open_signature_evaluation`: 照合済みの生成値に対する検証
- `refine_signature_evaluation`: 追加情報による再検証と、前後の評価結果の対応付け

検証処理における失敗は、戻り値の `Result` 型で返されます。

### 残余の記録

モジュール `semantic_residual_record` は、値の検証が返した残余を、`neco-quotient` の正規のバイト列として書き出し、読み込み、評価用関数へ渡します。記録は `schema`、`basis`、入力、義務の列の 4 つのフィールドを持ち、各フィールドの通信形式は既存の宣言の通信形式と同じです。

- `encode_semantic_residual`: 生成の `basis`、型の参照、値、義務の列から、正規のバイト列を作る。義務の列は順序と重複によらず同じバイト列になる
- `decode_semantic_residual`: バイト列を読み、欠けたフィールド、未知のフィールド、未知の `schema`、正規の順序から外れた義務の列を失敗として返す
- `open_semantic_residual`: 照合済みの生成と記録を受け取り、`basis` の一致と義務の集合の一致を確かめる。一致すると `SignatureEvaluation` を返し、その値は `refine_signature_evaluation` へ渡すことができる

失敗時は `SemanticResidualFailure` が返ります。

### 値の表現とポートの有無

借用値の検証には、値のデータ表現やポートの有無に応じた低水準関数を使用します。これらの関数は値の所属判定を行い、診断値を返します。

- `decide_view_slot`: JSON の借用ビューとポート省略の判定
- `materialize()`: 診断値から型解釈に必要な定義不足の有無を検査し、所有形式の分類結果を構築

ポートの省略と `null` 値は、次の列挙子で明確に区別されます。

```rust
SlotValue::Absent                   // ポート自体の省略
SlotValue::Null                     // ポート値としての null
SlotValue::Present(JsonValue::Null) // ポートがラップする値としての null
```

借用ビューは、借用対象フィールドの列から `JsonValueView::object` で構築します。借用ビューを所有値に変換する関数は `to_owned()` です。

### 繰り返しの検証

同一の型グラフに対して多数の値を反復して検証する場合は、型・数値・書式の各検証器を `PreparedValidator::new` で事前に初期化して再利用します。初期化済みの検証器は元の型グラフを不変参照として共有し、入力値ごとに書式照合用のワークスペースを独立して割り当てて処理します。

- `FormatWorkspace::empty()`: 空のワークスペース
- `FormatWorkspace::try_new(entries)`: 形式照合の途中結果を指定件数までキャッシュするワークスペース

件数を指定するコンストラクタは、メモリ領域の確保に失敗した場合に `FormatWorkspaceError` を返します。

## 精密化

リビジョン付き型宣言グラフおよび精密化の概念については、[docs/terminology.md](../../../docs/terminology.md#精密化) を参照してください。精密化処理では次の型を使用します。

- `VersionedSemanticGraph`: 型宣言グラフとリビジョンの組
- `AdditionalSemanticInformation`: 精密化処理へ渡す追加のデータモデル宣言および型ノード
- `SemanticGraphExtension`: 精密化検証を通過した追加情報
- `SignatureRefinement`: 精密化前後の評価結果の対応関係 ( `neco_quotient_certificate::VerifiedRefinement` の型エイリアス )

精密化後の再評価において、「残余」の結果は残余に分類された全条件を、「停止」の結果は停止原因と残余集合の両方を記録したまま保ちます。なお、有効な精密化の適用前に「確定」していた判定結果は、精密化後も「確定」のまま維持されます。

拒否理由ごとの精密化の失敗:

- `SemanticRefinementFailure::Profile`: 追加されたデータモデル宣言の構造不正
- `SemanticRefinementFailure::ObservationGraph`: リビジョン、ノード構造、または既存判定の保存条件違反
- `SemanticRefinementFailure::Evidence`: 精密化の証明データと評価の対応関係の不整合

## 証明書の照合失敗

証明書の照合に失敗した場合、`AdmissionFailure::Certificate` が返されます。このエラー値は、`neco-quotient` の不一致情報を保持します。

条件ごとの状態読み出し手順については、[neco-quotient](https://github.com/barineco/neco-quotient) の証明書クレートのドキュメントを参照してください。

## その他の機能

[プロジェクトの概要](../../../README.md) に記載の機能に加え、次の機能を提供します。

- 宣言の検証: 識別子の重複や未定義の型・定義への参照など、型や操作の宣言エラーを静的に検出
- 生成コード用ランタイム: 生成された Rust コードが実行時に呼び出す、値検証およびコーデックの共通処理
- HTTP アダプター: 別の crate `necoherence-http-adapter` ( [http/](http/) ) が提供する、ネットワーク副作用コマンドの実行処理

## 型付きの遷移モデル

ソルバーが探索対象とする型付き遷移モデルは、モジュール `typed_mapping` で定義されています。モデル定義とソルバーの探索結果については [docs/typed-transition-model.md](../../../docs/typed-transition-model.md) を参照してください。

## コード生成の受け入れ

形式 `ncoh-checked-generation@5` の JSON を受け入れる関数:

- `basis` の計算: `necoherence::signature_admission::signature_basis`
- 受け入れ検証: `necoherence::signature_admission::admit_signature_generation`

生成識別値 `basis` と受け入れ検証の規則は [docs/generation.md](../../../docs/generation.md) を参照してください。

## 合成の実行

検証を通過した合成を実行する関数:

- 実行の開始: `necoherence::semantic_execution::start`
- 実行の再開: `necoherence::semantic_execution::resume`

実行に渡す合成は、受け入れ検証の結果から次の順で得ます。

- 受け入れ検証の結果: `CheckedSignatureGeneration`
- 準備: `prepare_admission()`
- 合成の取り出し: `admitted()` ( `AdmittedComposition` を返す )
- 実行の入力の作成: `PreparedRun::new` ( 実行の開始に渡す )

導出木を合成問題に対して検証する関数 ( `necoherence_composition_solver::verification::verify_composition` ) は、合成のソルバーの crate にあります。詳細は [solver/composition/README.md](../../../solver/composition/README.md) を参照してください。

実行の入力、関数の実装、進捗状態の意味は [docs/composition.md](../../../docs/composition.md#合成の実行) を参照してください。

## 付属のツール

型と操作の宣言から Rust の型定義とコーデックを生成するコード生成ツール、および到達可能状態を探索するソルバーは、それぞれ次のディレクトリにあります。

- [`generator/`](../../../generator/)
- [`solver/`](../../../solver/)

これらの付属ツールのライセンスは AGPL-3.0-only です。

## インストール

```bash
cargo add necoherence
```

基本モデル、値検証、コーデック、純粋な `network_effect` モデルは feature を指定せずに利用できます。一方で、HTTP アダプターは別の crate として提供されます。

- `necoherence-http-adapter`: [`http/`](http/)

ターゲット環境が WebAssembly の場合に基本機能を利用する際は、次のコマンドで適合性を検査できます。

```bash
cargo check --lib --target wasm32-unknown-unknown --no-default-features
```

## 開発時

以下のコマンドでフォーマット検査、静的解析、テストを実行できます。

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
cargo check --lib --target wasm32-unknown-unknown --no-default-features
```

## ライセンス

[MIT](LICENSE)
