# Necoherence のツール

[プロジェクトの概要](../README-ja.md) | [English](README.md)

このディレクトリには、Necoherence の生成器とソルバーを、言語ごとに収めています。
生成器は宣言からコードを生成し、ソルバーは遷移を探索して証拠を返します。
生成されたコードは、その言語の MIT License の実装と組み合わせて使います。
ソルバーが返す到達、閉包、非循環の証拠も、その実装が検査します。
MIT License の実装は、次のディレクトリにあります。

- [lean/](../lean/)
- [python/](../python/)
- [rust/](../rust/)
- [typescript/](../typescript/)
- [java/](../java/)
- [gleam/](../gleam/)

## ツール

- 生成器: 型と操作の宣言から、各言語の型とコーデックを生成する
- ソルバー: 場所、遷移、トークンからなる型付き遷移モデルを探索し、到達、閉包 ( 到達できるすべての状態の集合 )、デッドロック、非循環のいずれかの証拠を返す

生成器とソルバーの両方を備えるのは、Lean と Rust と Gleam です。

| 言語 | 生成器 | ソルバー |
| --- | --- | --- |
| Lean | あり | あり |
| Rust | あり | あり |
| Gleam | あり | あり |
| Python | あり | なし |
| TypeScript | あり | なし |
| Java | あり | なし |

### 生成器

入力: 形式 `ncoh-checked-generation@4` の JSON 文書 1 つ ( 以下、入力文書 ) 。この形式は、次の JSON Schema が定めます。

- [ncoh-checked-generation-v4.schema.json](../comparison/declaration/ncoh-checked-generation-v4.schema.json)

文書のフィールドは 5 つです。

- `schema`: 文字列 `ncoh-checked-generation@4`
- `basis`: 生成の前提。生成対象を固定する情報で、宣言集合の識別子とリビジョン、および宣言のグラフ、由来、メタデータ、合成の問題、エントリポイントそれぞれのダイジェストを含む
- `signatures`: 形式 `ncoh-type-signatures@1` の宣言集合。主な内容は次の 3 種類
  - `nodes`: 宣言した型
  - `definitions`: 値、シンボル、メッセージ、操作。操作は入力と結果 ( outcome ) を宣言する
  - `annotations`: 宣言集合全体、グループ、定義、型、結果 ( outcome ) のいずれかに付けるメタデータ
- `composition`: `null`、または合成の問題とその導出。生成器は、導出を検査してから使う
- `entrypoints`: 公開する定義の一覧。それぞれ識別子と定義の ID を持つ

呼び出し側は、もう 1 つの入力として、期待する生成の前提 ( `basis` フィールドの形 ) を渡します。これは、入力文書とは別に入手したものです。
生成器が文書を受理するのは、文書の `basis` が期待する値と等しく、文書の内容のダイジェストとも一致する場合だけです。

生成の前提を計算する関数は、MIT License の実装にあります。

- Python: `signature_basis`
- TypeScript: `signatureBasis`
- Rust: `signature_basis` ( `necoherence::signature_admission` )
- Java: `TypeSignatures.basis`
- Gleam: `generation_basis`

出力: 対象の言語で書かれた、1 つのファイルのソースコードです。出力には、次の内容が含まれます。

- 宣言した値の型とコーデック
- 各操作の引数の型と結果の型
- 宣言した注釈
- `composition` を渡した場合は、その合成を実行するコード

出力の先頭の行は、対象の言語のコメントの書式で書かれた `SPDX-License-Identifier: MIT` です。
生成されたコードが依存するのは、その言語の MIT License の実装だけです。

失敗: 入力文書が不正な場合、期待する生成の前提と食い違う場合、宣言や導出が拒否された場合は、エラーを返します。
エラーの形は言語ごとに異なり、「言語ごとの実装」の節に挙げます。

### ソルバー

ソルバーは 2 つの部分からなり、どちらも、すべての入力に対して明示的な結果を返します。

型付き遷移モデルのソルバー:

- 入力: 型付き遷移モデルの `SolverInput`。次の部分を持つ
  - 場所、遷移、入力の束縛
  - 目標、宣言のグラフ、初期のマーキング ( 各場所のトークンの配置 )
  - 上限 ( `max_bindings` と `max_search_steps` )
- モデル: 定義は MIT License の実装にある
  - Lean: `Necoherence.TypedMapping`
  - Rust: `necoherence::typed_mapping`
  - Gleam: `necoherence/typed_mapping`
- 操作: 到達可能性、デッドロック、整礎性

次の表の結果名は Rust のものです。Lean と Gleam にも同じ結果があり、命名は言語ごとに異なります。

閉包は、到達できるすべてのマーキングの集合です。

| 操作 | 結果 | 意味 |
| --- | --- | --- |
| 到達可能性 | `Reachable` | 目標に到達します。証拠は、遷移の経路と最終のマーキングです |
| 到達可能性 | `Unreachable` | 到達できるすべての状態を調べ尽くしました。証拠は、その閉包です |
| デッドロック | `Deadlocked` | 目標が満たされず、実行できる遷移もありません。証拠は、そのマーキングです |
| デッドロック | `NotDeadlocked` | 実行できる遷移の一覧を結果に含めます |
| 整礎性 | `WellFounded` | 探索した閉包が非循環です。証拠は、その閉包です |
| 整礎性 | `NotWellFounded` | マーキングが繰り返します。証拠は、その循環です |
| 各操作 | `Invalid` | 宣言が不正です。理由を結果に持ちます |
| 各操作 | `Unknown` | 束縛の上限か探索ステップの上限に達して、探索が止まっています |

呼び出し側のプログラムが契約に違反した場合、Rust と Gleam は別に `SolverFailure` を返します。
Lean の関数は、上の結果だけを返します。

合成の探索:

- 入力: 合成の問題 ( 入力文書の `composition.problem` ) から作った `PreparedCompositionInput`
  - 合成とは、宣言した関数を組み合わせて、初期の入力から目標の値を作る計画
  - 問題は、関数のシグネチャ、初期の入力、目標を宣言する
- 結果: 次の 4 つのいずれか
  - `Solved`: 検査済みの導出
  - `Unreachable`: 閉包
  - `Unknown`: 未解決の条件
  - `Ambiguous`: 候補の計画
- 結果の使い方: `Solved` の導出は、入力文書の `composition.derivation` に入れる。生成器と MIT License の実装が、そこで検査する

## 言語ごとの実装

どのツールも、関数として呼び出します。
呼び出しに使う関数を、言語ごとに次の節に挙げます。
Lean には、生成器のコマンドもあります。

### Lean

- ディレクトリ: [lean/](lean/)
- パッケージ: `necoherence-tools`
- 依存先: [../lean/](../lean/) の MIT License のパッケージ `necoherence`

生成器のコマンドは、`tools/lean` のディレクトリで次のように実行します。

```bash
lake exe semantic_generation <input.json> <trusted-basis.json> <output.lean>
```

2 つ目のファイルには、期待する生成の前提を、入力文書の `basis` と同じ形で入れます。
コマンドは、3 つ目のパスに Lean のソースを書き、`generated signature nodes=N` を表示します。
入力が不正な場合、コマンドはエラーで終了します。

呼び出しに使う関数は次のとおりです。

- 生成器: `NecoherenceTools.SignatureComposition.generate`。`Except String String` を返す
- ソルバー: `NecoherenceTools.checkReachability`
- ソルバー: `NecoherenceTools.checkDeadlock`
- ソルバー: `NecoherenceTools.checkWellFoundedness`
- 合成の探索: `NecoherenceTools.CompositionSearch.derive`

### Rust

- ディレクトリ: [rust/](rust/)
- クレート: `necoherence-tools` ( `publish = false` )
- 依存先: [../rust/](../rust/) の MIT License のクレート ( パスで指定 )
- 必要な環境: Rust 1.88 以降

```rust
// 生成器
necoherence_tools::renderer::render_signature_exchange(
    expected: &SignatureGenerationBasis, text: &str) -> Result<String, RenderFailure>
necoherence_tools::renderer::render_signature_composition(
    expected: &SignatureGenerationBasis, text: &str) -> Result<String, RenderFailure>
necoherence_tools::renderer::render_checked(checked: &CheckedLibrary) -> Result<String, RenderFailure>
necoherence_tools::renderer::render_generation(input: &SignatureGenerationInput) -> Result<String, RenderFailure>

// ソルバー
necoherence_tools::typed_mapping_solver::check_reachability(input: &SolverInput) -> Result<ReachabilityResult, SolverFailure>
necoherence_tools::typed_mapping_solver::check_deadlock(input: &SolverInput) -> Result<DeadlockResult, SolverFailure>
necoherence_tools::typed_mapping_solver::check_well_foundedness(input: &SolverInput) -> Result<WellFoundednessResult, SolverFailure>
necoherence_tools::composition_search::derive(prepared: &PreparedCompositionInput) -> Result<CompositionDecision, CompositionEngineFailure>
```

`render_checked` は、`check_library` が検査済みの型ライブラリを受け取り、その型とコーデックを生成します。
`render_generation` は `SignatureGenerationInput` 型の入力を受け取り、
`check_library` でその型ライブラリを検査し、型・コーデック・操作を含む出力を生成します。
入力の `composition` フィールドがある場合は、
`admit_signature_generation` で入力自身が宣言する検査の基準 ( `basis` ) に対して入力を受理し、関数構成の断片を出力へ追加します。

`render_signature_composition` は `render_signature_exchange` と同じ 2 つの入力を取り、
`composition` フィールドを持つ入力文書に対して、関数構成の断片だけを生成します。
断片は、同じ宣言集合に対して事前の `render_library` または `render_checked` の
呼び出しが生成した生成先の具象型と `Context` 型を再利用します。
この生成先の具象型のモジュールの生成は、1 回だけです。

呼び出し側は、断片のテキスト全体をそのまま、構成ごとの名前を持つ自分のモジュールの中へ入れ子にし、そのモジュールを生成先の具象型の 1 つのモジュールの中に置きます。
断片自身は内部に `composed` という名前のモジュールと `pub use` をそのまま保ち、呼び出し側のモジュールはそれを包む外側の層として加わります。

```rust
pub mod recipe_a {
    use super::*;
    // render_signature_composition が返す断片のテキストを、そのまま貼る
    // 断片の内部は pub mod composed { ... } と pub use composed::*; のまま
}
```

`render_library`/`render_checked` は、
`Context` 型と、受理済みの `GenerationContext` を受け取る構築子を生成します。
`render_generation` は、これに加えて用意済みの `generation_context()` 生成関数を出力の一部として生成します。
型と関数構成の断片を別々に生成する呼び出し側は、ランタイムの関数 `necoherence::semantic_exchange::signature_generation_context` を使って、`GenerationContext` を自分で組み立てます。

```rust
Context::new(generation: &GenerationContext) -> Self
necoherence::semantic_exchange::signature_generation_context(
    expected: &SignatureGenerationBasis, text: &str,
) -> Result<GenerationContext, GenerationFailure>
```

関数構成の断片が公開する要素:

```rust
pub struct CompositionInput { /* 引数の入力ポートごとに 1 フィールド */ }
pub struct CompositionOutput { /* 目標の出力ポートごとに 1 フィールド */ }
pub enum DeclaredFailure { /* 宣言した失敗の埋め込み先ごとに 1 つの選択肢 */ }
pub enum CompositionOutcome {
    Success(CompositionOutput),
    DeclaredFailure(DeclaredFailure),
}
```

`CompositionInput`・`CompositionOutput` の各フィールドと、
各 `DeclaredFailure` の値は、ポートの生成先の具象型を、省略可能なポートなら `Option<_>` で、
nullable なポートなら `rt::Nullable<_>` で包んだ型です。
両方の性質を持つポートでの扱いは、両方を重ねて包む形です。

`Providers` のメソッド名は、`site_` に続けて、
呼び出し箇所の識別子と関数の識別子をそれぞれ正規化した文字列を `_` でつないだ名前です。

```rust
pub trait Providers {
    type Failure;
    fn site_first_transform(
        &mut self, input: site_first_transform_Input, resources: &[BoundResource],
    ) -> Result<site_first_transform_Outcome, Self::Failure>;
    // 呼び出し箇所ごとに、ポートに固有の入力と結果の型を持つ method を 1 個持つ
}
```

正規化は、ASCII の英数字以外の文字を `_` へ置き換え、先頭が数字の場合は `_` を前置します。
箇所の識別子や関数の識別子に含まれる `.` などの文字も、この正規化の対象に含めます。

```rust
pub struct BoundResource {
    pub reference: ResourceLotRef,
    pub lot: ResourceLot,
    pub requirement: ResourceRequirement,
}
pub enum CompositionFailure<E> {
    Runtime { cause: rt::RuntimeFailure, provenance: BindingProvenance },
    Provider { site: SiteId, function: FunctionRef, cause: E },
}
pub fn execute<P: Providers>(
    cx: &Context<'_>, input: CompositionInput, providers: &mut P,
) -> Result<CompositionOutcome, CompositionFailure<P::Failure>>
```

`BoundResource` の中身は、`semantic_composition` が既に宣言している次の型であり、読み取り専用の宣言値です。

```rust
pub struct ResourceLot {
    pub id: LotId,
    pub token_type: TypeRef,
    pub producer: ResourceProducer,
    pub revision: Nat,
    pub quantity: Nat,
    pub provenance: String,
}
pub struct ResourceRequirement {
    pub id: RequirementId,
    pub token_type: TypeRef,
    pub mode: BindingMode,
    pub multiplicity: Nat,
    pub required_revision: Nat,
    pub identity: ResourceIdentityConstraint,
}
```

同じ `execute` 呼び出し内で先行する手順が資源を消費すると、
`ResourceLot` の `quantity` はその分だけ減ります。

`CompositionFailure::Runtime` は、生成コード自身の実行が起こす検査・表現の失敗を運びます。
`CompositionFailure::Provider` は、呼び出し側の実装自身の失敗値をそのまま運びます。

Bytes と raw body のポートは、生成された `Vec<u8>` を包む具象型を使います。
生成コードは、値をそのまま保つ crate のコーデックを内部で呼び出します。
この生成先の具象型を使う形の適用範囲は、関数構成のポート自身の最上位のフィールドです。

`render_checked` が `Shape::Product` の型に対して生成する型定義は、
自身のフィールドを `Option<rt::JsonValue>` のまま持ちます。
生成先の具象型が Product 型である関数構成のポートは、その内部に同じ表現を運びます。

生成コードをコンパイルして実行する利用例のテストが、実際の呼び出し側全体を検証します: [`tools/rust/tests/semantic_composition_execution.rs`](rust/tests/semantic_composition_execution.rs)。

### Gleam

- ディレクトリ: [gleam/](gleam/)
- パッケージ: `necoherence_tools`
- 依存先: [../gleam/](../gleam/) の MIT License のパッケージ ( パスで指定 )
- ターゲット: Erlang

```gleam
// 生成器
necoherence/semantic_signatures.admit_generation(expected_json: String, input_json: String) -> Result(CheckedGeneration, Failure)
necoherence/semantic_signatures.generation_requirement(checked: CheckedGeneration) -> GenerationRequirement
necoherence/semantic_signatures.require_generation(required: GenerationRequirement, checked: CheckedGeneration) -> Result(CheckedGeneration, GenerationMismatch)
necoherence_tools/renderer.render_signatures(checked: CheckedGeneration) -> Result(String, RenderFailure)

// ソルバー
necoherence_tools/typed_mapping_solver.check_reachability(input: SolverInput) -> Result(ReachabilityResult, SolverFailure)
necoherence_tools/typed_mapping_solver.check_deadlock(input: SolverInput) -> Result(DeadlockResult, SolverFailure)
necoherence_tools/typed_mapping_solver.check_well_foundedness(input: SolverInput) -> Result(WellFoundednessResult, SolverFailure)
necoherence_tools/composition_search.derive_composition(prepared: PreparedCompositionInput) -> Result(CompositionDecision, CompositionEngineFailure)
```

受け入れの関数は MIT License のパッケージにあり、その結果が生成器の入力になります。
生成した初期化関数は、コードに組み込まれた型付きの生成要件と、呼び出し側の検査済みの生成値を照合します。
初期化に成功すると、文脈は同じ検査済みの生成値を保持し、生成した値、コーデック、操作がその値を使います。

Gleam の生成器は、次の値から公開する名前を作ります。

- 型と構築子: 宣言した型の識別子と、シグネチャの転送で使う識別子
- 値: シグネチャの転送で使う識別子
- ラベル: フィールドの転送で使う名前、ポートの識別子、結果の識別子

名前の変換規則は次のとおりです。

- ASCII の区切りで単語を分ける
- ASCII 以外の文字を表すスカラー値は、安定したエスケープ表現へ変換する
- 数字で始まる名前と Gleam の予約語には、役割を表す接頭辞を付ける

生成した名前が衝突した場合は、衝突した双方の宣言元を含む `IdentifierCollision` を返します。

### Python

- ディレクトリ: [python/](python/)
- パッケージ: `necoherence-tools`
- 必要な環境: Python 3.12 以降と、MIT License のパッケージ `necoherence`
- 備えるツール: 生成器

```python
necoherence_tools.render_expected(expected_basis: ExpectedSignatureBasis, exchange: str) -> str
necoherence_tools.render_checked(checked: CheckedSignatureGeneration) -> str
```

- `ExpectedSignatureBasis` は `necoherence.type_signatures` にある
- `render_checked` の引数は、`admit_signature_generation` で受け入れた入力
- 入力が拒否されると、`GenerationFailure` を送出する

### TypeScript

- ディレクトリ: [typescript/](typescript/)
- パッケージ: `necoherence-tools` ( 非公開、ES モジュール )
- 依存先: [../typescript/](../typescript/) の MIT License のパッケージ
- 備えるツール: 生成器

```ts
renderSignatureGeneration(checked: CheckedSignatureGeneration, runtimeModule = "necoherence"): string
```

- `checked` の値は、パッケージ `necoherence` の関数から得る
- 関数: `semanticSignatures.admitSignatureGeneration(basis, exchangeJson)`
- 入力が拒否されると、この関数は `{ tag: "Failed", failure }` を返す

### Java

- ディレクトリ: [java/](java/)
- 備えるツール: 生成器
- ビルド: [../java/](../java/) の MIT License のソースと合わせて、`javac` でビルドする
- 必要な環境: Java 21

```java
necoherence.tools.renderer.Renderer.render(
    SemanticGeneration.GenerationBasis basis, String exchange, Renderer.JavaTarget target) -> Renderer.RenderResult
```

- `JavaTarget`: 出力の Java パッケージ名とクラス名
- `RenderResult`: 2 つの場合のいずれか
  - `Rendered`: ソースを持つ
  - `InvalidGeneration`: パスと理由を持つ
- `Renderer.renderChecked` の引数は、MIT License のソースにある `TypeSignatures.admitGeneration` で受け入れた入力

## ビルドとテスト

手順は、CI のワークフローの `tools-*` のジョブが実行するコマンドと同じです。

- [ci.yml](../.github/workflows/ci.yml)

各コマンドは、言語ごとに示したディレクトリで実行します。

### Lean

ツールチェーンは [lean-toolchain](lean/lean-toolchain) が指定する版を使い、`tools/lean` で実行します。

```bash
lake build NecoherenceTools NecoherenceToolsTest
```

### Gleam

Gleam 1.17 以降を使い、`tools/gleam` で実行します。

```bash
gleam format --check
gleam build --warnings-as-errors
gleam test
```

### Rust

`tools/rust` で実行します。

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

### Python

Python 3.12 以降を使います。
はじめに、リポジトリのルートで次のコマンドを実行します。

```bash
python -m pip install -e python
python -m pip install -e "tools/python[dev]"
```

続けて、`tools/python` で次のコマンドを実行します。

```bash
python -m pytest -q
python -m mypy src tests
```

### TypeScript

Node.js 22 を使います。
はじめに、`typescript` で次のコマンドを実行します。

```bash
npm ci
npm run build
```

続けて、`tools/typescript` で次のコマンドを実行します。

```bash
npm ci
npm run build
npm run typecheck
npm test
```

### Java

Java のツールは、MIT License のソースと合わせてビルドし、`main` メソッドを持つテストを実行します。
`SemanticSignatureCompositionTest` は、Rust のツールを使う `comparison/declaration/signature_generator` でシナリオを生成します。
このため、Java 21 と Rust のツールチェーンを用意してから、リポジトリのルートで次のコマンドを実行します。

```bash
mkdir -p java/lib tools/java/build/classes tools/java/build/test-classes
curl --fail --location --silent --show-error \
  --output java/lib/junit-platform-console-standalone-1.10.2.jar \
  https://repo1.maven.org/maven2/org/junit/platform/junit-platform-console-standalone/1.10.2/junit-platform-console-standalone-1.10.2.jar
printf '%s  %s\n' \
  a1de557821293ce903c213c694165fff532cf92081bac4238b9e05b35f04f43f \
  java/lib/junit-platform-console-standalone-1.10.2.jar | shasum -a 256 -c -
find java/src/main/java tools/java/src/main/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 -d tools/java/build/classes
find java/src/test/java/necoherence/semantic tools/java/src/test/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 \
      -cp tools/java/build/classes:java/lib/junit-platform-console-standalone-1.10.2.jar \
      -d tools/java/build/test-classes
for test in SemanticInvariantAdapterTest SemanticJavaSizeTest SemanticJavaTargetTest SemanticSignatureCompositionTest SemanticSignatureTest GeneratedJavaSemanticTest; do
  java -Duser.language=en -cp tools/java/build/classes:tools/java/build/test-classes:java/lib/junit-platform-console-standalone-1.10.2.jar \
    "necoherence.tools.renderer.$test"
done
for test in ProfileLibraryPredicateTest InclusionAndSamplesTest DeclarationWireTest; do
  java -Duser.language=en -cp tools/java/build/classes:tools/java/build/test-classes:java/lib/junit-platform-console-standalone-1.10.2.jar \
    "necoherence.semantic.$test"
done
```

## ライセンス

このディレクトリのツールのライセンスは [AGPL-3.0-only](LICENSE) です。
依存の向きは一方向で、ツールから MIT License の実装へ向かいます。

生成器が出力したコードと、ソルバーが返す証拠は、MIT License で利用できます。
生成したコードの先頭の行にも、そのことを記しています。
入力文書を定める JSON Schema のライセンスも、MIT License です。

ファイルごとのライセンスは、各ファイルの先頭の SPDX の宣言または [REUSE.toml](../REUSE.toml) で確かめられます。
