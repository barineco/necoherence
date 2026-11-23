# ソルバー

型付きの遷移モデルについて、マーキングの到達、デッドロック、整礎性 ( 同じマーキングを繰り返す閉路の有無 ) を探索します。

モデルの定義は [docs/typed-transition-model.md](../docs/typed-transition-model.md) を参照してください。

## 実装

| 言語 | パス | パッケージ |
|---|---|---|
| Rust | `solver/rust` | `necoherence-solver` |
| Lean | `solver/lean` | `necoherence-solver` |

どちらの実装も探索機能を備えています。入力の型と証拠の検証関数は、基本のパッケージ `necoherence` にあります。

## 導入

各実装のうち Rust の crate は、`Cargo.toml` の `[dependencies]` に追加します。動作には Rust 1.88 以降が必要です。

```toml
[dependencies]
necoherence-solver = "0.3.0"
```

## 入力

探索の入力は `SolverInput` で表現されます。全てのフィールドが必須です。

| フィールド | 内容 |
|---|---|
| `places` | 場所と、置かれるトークンの型 |
| `transitions` | 遷移と、その入力、出力、失敗の場所 |
| `bindings` | 遷移の入力とトークンの結び付け |
| `goal` | 目標の条件 |
| `graph` | 宣言のグラフ |
| `marking` | 初期のマーキング |
| `bound` | 探索の上限 |

## 操作と結果

### `check_reachability`

- 到達した場合: `Reachable` ( 経路と最終のマーキング )
- 到達しない場合: `Unreachable` ( 探索したマーキングの閉包 )

### `check_deadlock`

- デッドロックした場合: `Deadlocked` ( 進めない状態のマーキング )
- デッドロックしない場合: `NotDeadlocked`

### `check_well_foundedness`

- 整礎の場合: `WellFounded`
- 整礎でない場合: `NotWellFounded` ( 閉路 )

全ての操作に共通して、宣言が不整合な場合は `Invalid`、上限に達した場合は `Unknown` が結果になります。

## 探索の上限

探索の順序は操作ごとに異なります。

- `check_reachability`: 幅優先
- `check_deadlock`: 幅優先
- `check_well_foundedness`: 深さ優先

指定できる上限:

- 探索の手数の上限: `max_search_steps`
- 結び付けの数の上限: `max_bindings`

上限は入力の `bound` で指定します。上限を超えた場合、結果は `Unknown` になります。

## 証拠の検証

基本パッケージ `necoherence` の関数で、結果の証拠を検証します。

- 到達の経路: `verify_reachability_witness`
- 到達しない場合の閉包: `verify_closure_witness`
- 非循環 ( 閉路がないこと ) の証拠: `verify_acyclic_witness`

## 使用例

利用方法の具体例は、[solver/composition/rust/examples/reachability_witness.rs](composition/rust/examples/reachability_witness.rs) を参照してください。出力は `reachable by ["run"]` と `unreachable; closure of 2 markings` です。

## 検査

```sh
cd solver/rust && cargo test
cd solver/lean && lake build NecoherenceSolver NecoherenceSolverTest
```

比較スクリプト `solver/verification/check.py` で、Lean と Rust の結果を検証用の別実装の結果と比較できます。

## 合成のソルバー

宣言した関数の組み合わせを探索するソルバーは `composition/` にあります。詳細は [composition/README.md](composition/README.md) を参照してください。

## ライセンス

AGPL-3.0-only
