# 機能

[Necoherence の概要](../README.md)

全 6 言語の実装で、次の機能族の操作を共通して提供します。操作は Lean 4 の実装で定め、その性質を定理で証明しています。定理の範囲は [構成と証明](construction-as-proof.md) を参照してください。他の 5 言語の実装でも、各言語の型に従う結果と失敗の表現を共通の JSON 表現へ正規化し、Lean の実装と結果が一致するかを照合して検証しています。保証範囲は [言語間の一致](#言語間の一致) を参照してください。

## 機能族

| 機能族 | 内容 |
| --- | --- |
| Core | 観測したリビジョンに基づくリソース更新と、失敗要因の分類 |
| Call | 宣言された操作の実行と、その結果の観測 |
| Iteration | 上限回数を指定した反復処理 ( fold, recurse, closure ) |
| Store | リソースごとの値とリビジョンの記録 |
| Record | 実行した操作の記録 ( 宣言、入力、結果 ) |
| Reconcile | 操作の記録とリソースの現在状態との照合 |
| Request progression | リクエストの開始から完了までの追跡 |
| Dynamic admission | 処理能力の余力に基づくリクエスト開始判定 |
| Step transition | 入力 1 件ごとの状態遷移 |
| File effect | ファイル操作とその結果の観測 |
| Network effect | HTTP リクエストの試行、実行ホストでの観測、再試行の制御 |

各機能族の操作の名前は、照合で用いるものと同じです。

```text
core                 lookup, bump, commandOf, apply
call                 immediateOf, deferredOf, io, issue
iteration            fold, recurse, closure
store                storeOf, storeEntries, observe, apply, worldOf
record               recordOf, recordOnBasis, hasEdge
reconcile            reconcile, coherent
request_progression  empty, submit, decideStart, applyStartObservation,
                     applyCompletionObservation, decideCancel,
                     derivePending, deriveInFlight, deriveConcurrent
dynamic_admission    elideAdmissionProvenance, admitDynamicRequest
step_transition      step
file_effect          normalizePath, lookupDigest, setDigest, track, read, replace
network_effect       readNetworkState, prepare, sendCommand, cancelCommand,
                     observeStart, observe, annotateEffect, retry
```

各操作は、入力に対して結果または明示的な失敗を返します。

### ネットワーク副作用の指示と観測

- 指示 `send`: リクエストの送信指示
- 指示 `observe`: 開始済みリクエストの観測指示
- 観測 `start`: リクエスト試行開始の観測結果
- 観測 `host`: 実行ホストでの観測結果

実際の I/O 処理は呼び出し元のアダプターが担当し、コアパッケージでは観測結果に応じてネットワーク副作用の状態を更新します。

## 合成

合成の探索、検証、実行は [合成](composition.md) を参照してください。

## 言語間の一致

- 機能族の操作: 6 実装
- ネットワーク副作用の状態遷移: 6 実装
- 宣言とデータモデル宣言の判定: 6 実装
- 合成の検証: Lean と Rust
- 合成の実行: 6 実装のコアパッケージと、コード生成ツールが出力したコード

照合では Lean の実装から出力を生成し、同じ入力を他の実装に渡した出力と比較して、与えた入力についての一致を保証範囲とします。機能族の操作の照合では、値域の型宣言から全操作を網羅する入力を生成します。

### 照合の実行

言語間の照合は CI ワークフロー ( [ci.yml](../.github/workflows/ci.yml) ) で実行されます。

| 機能 | 照合プログラム |
| --- | --- |
| 機能族の操作 | `verification/shared_operations` |
| ネットワーク副作用 | `verification/network_effect` |
| 宣言とデータモデル宣言 | `verification/declaration` |
| 合成の検証 | `solver/composition/verification` |
| 合成の実行 | `verification/execution` |
