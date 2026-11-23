# Lean の定義と定理

[Necoherence の概要](../README.md)

本パッケージ ( Lean 4 ) の実装では、検証済みデータ型が構造体として定義されており、数学的条件を満たすことの証明項をフィールドに直接格納します。

到達可能性の証拠の型と検証関数:

- `CheckedReachability`: 入力の妥当性、上限の範囲、経路再生の一致、目標条件の成立に関する証明項を格納する型
- `verifyReachabilityWitness`: この型のインスタンス、または検証失敗の理由を返す検証関数

各定理は検証済みインスタンスを前提条件として受け取り、その値が持つ意味論を結論として証明します。したがって、検証済みインスタンスが構築できた時点で、その定理の結論が数学的に成立します。

各定理の定義ファイルは、[`packages/lean/Necoherence/`](../packages/lean/Necoherence/) に収録されています。

## 型付き遷移モデルに関する定理

ソルバーの探索対象となる状態遷移モデルに関する定理:

| 定理名 | 内容 | 定義ファイル |
| --- | --- | --- |
| `step_deterministic` | 妥当な入力では、同一マーキングから同一遷移を発火させた結果状態は一意に定まる | `TypedMapping.lean` |
| `pathReplay_implies_pathExec` | 経路の再生が成功すれば、その経路は遷移関係に従って実行可能である | `TypedMapping.lean` |
| `pathExec_implies_pathReplay` | 遷移関係に従って実行可能な経路は、再生しても同一の結果状態に至る | `TypedMapping.lean` |
| `resourceWitnessSound` | 検証に合格した到達の証拠では、経路が初期マーキングから実行可能であり、最終マーキングで目標が成立する | `SemanticComposition.lean` |
| `resourceClosureSound` | 検証に合格した閉包の証拠では、初期マーキングから実行可能な任意の到達先で目標が不成立である | `SemanticComposition.lean` |
| `resourceAcyclicSound` | 検証に合格した非循環の証拠では、到達可能マーキングから出発して同一マーキングへ戻る空でない循環経路が存在しない | `SemanticComposition.lean` |

## 型の包含と空の型に関する定理

型宣言の代数構造に関する定理:

| 定理名 | 内容 | 定義ファイル |
| --- | --- | --- |
| `inclusionWitnessSound` | 検証に合格した型包含の証拠では、包含元の型に属するすべての値が包含先の型にも属する | `SemanticComposition.lean` |
| `counterexampleWitnessSound` | 検証に合格した反例では、その値が包含元の型に属し、包含先の型には属さない | `SemanticComposition.lean` |
| `emptyTypesSound` | 検証に合格した空の型集合では、該当する型に属する値が存在しない | `SemanticComposition.lean` |

## 合成の探索に関する定理

合成の探索は、目標型の値を構成する手順を探索するため、構成的論理における証明探索 ( Proof Search ) に相当します。

合成探索に関する定理:

| 定理名 | 内容 | 定義ファイル |
| --- | --- | --- |
| `compositionGoalReachable` | 検証に合格した合成では、ある分岐が正常終了し、その出力が目標型を満たし、リソース経路が実行可能である | `SemanticComposition.lean` |
| `checkedWitnessSound` | 検証に合格した合成では、計画の型付けが妥当であり、全分岐でリソース経路が実行可能かつ目標が成立し、循環が存在しない | `SemanticComposition.lean` |
| `uniqueSelectionSound` | 一意選択を要求した場合、検証に合格した合成の計画は閉包内で唯一の正規計画である | `SemanticComposition.lean` |
| `compositionClosureSound` | 検証に合格した到達不能判定では、状態閉包が閉じており、目標に至る合成が存在しない | `SemanticComposition.lean` |
