# Necoherence (Lean 4)

[プロジェクトの概要](../../README.md)

このパッケージは、Necoherence の Lean 4 実装です。

- Lean ツールチェーン v4.32.1

[プロジェクトの概要](../../README.md) に挙げた全機能を実行可能な形式仕様として記述しており、他言語の実装はこの定義を基準仕様として参照します。

型宣言や生成ライブラリを検証する際は、データモデル宣言 ( 型 `VersionedSemanticProfile` ) を渡し、処理を開始する前にデータモデル宣言とライブラリの整合性を検証します。値の検証、射影、実行時に使用するワイヤ転送キーは、このデータモデル宣言が定めるラッパー、型タグ、シールド形式の定義によって定まります。

## 宣言の検証

検証する内容:

- 型と操作の宣言が満たすべき数学的条件
- 検証に合格した宣言集合において、参照される型がすべて定義済みであることを保証する定理
- 操作を安全に拡張しても元の動作結果が保存されることを示す定理
- 生成された Lean コードが使用する共通定義群

## 型付きの遷移モデル

モジュール `Necoherence.TypedMapping` は、ソルバーが探索対象とする状態遷移モデルを定義しています。モデルは場所 ( プレース ) と遷移 ( トランジション ) とトークンから構成されます。

- 場所、遷移、トークンのデータ型定義
- ソルバーへの入力データの妥当性検証
- 遷移の単一ステップ適用処理、および遷移列を順次適用する経路再生処理
- ソルバーが返す証明データの型定義 ( 到達可能性、閉包、デッドロック、非循環性 )
- 不正入力の拒否理由が実際に成り立つこと、および経路再生が遷移関係と一致することを保証する定理

モデル定義とソルバーの探索結果については [docs/typed-transition-model.md](../../docs/typed-transition-model.md) を参照してください。

## 残余の整合性

ディレクトリ [residual-coherence/lean](../../residual-coherence/lean/) には、残余量の有限モデルと、任意のモデルにおいて成立する定理 ( 残余量が非負であることなど ) が含まれます。残余量とは、導出された点のうち宣言に含まれない点が測度に寄与する総量です。

## コード生成の受け入れ

形式 `ncoh-checked-generation@5` の JSON を受け入れる関数:

- `basis` の計算: `Necoherence.SignatureGeneration.basis`
- 受け入れ検証: `Necoherence.SignatureGeneration.admit`

生成識別値 `basis` と受け入れ検証の規則は [docs/generation.md](../../docs/generation.md) を参照してください。

## 合成の検証と実行

合成を検証し、検証を通過した合成を実行する関数:

- 検証: `Necoherence.SemanticComposition.verifyComposition`
- 実行の開始: `Necoherence.SemanticExecution.start`
- 実行の再開: `Necoherence.SemanticExecution.resume`

実行の入力、関数の実装、進捗状態の意味は [docs/composition.md](../../docs/composition.md#合成の実行) を参照してください。

## 付属のツール

各言語のコード生成ツールおよびソルバーの Lean 実装は、それぞれ次のディレクトリにあります。

- [`generator/lean`](../../generator/lean/)
- [`solver/lean`](../../solver/lean/)

これらの付属ツールのライセンスは AGPL-3.0-only です。残余の整合性を検証する Python ツールは [residual-coherence](../../residual-coherence/) にあります。

## ビルドと実行

ディレクトリ `packages/lean` で次のコマンドを実行すると、定理の形式証明を含むビルドとテストを行えます。

```bash
lake build
lake env lean --run Tests/ProofCompleteness.lean
```

## ライセンス

[MIT](LICENSE)
