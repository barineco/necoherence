# 合成のソルバー

宣言した関数の入力と結果の型から、初期の入力を目標の値へつなぐ関数の呼び出しの計画 ( 合成 ) を探索するソルバーです。

合成の候補ごとに、リソースの経路をソルバーで調べ、到達と整礎を確かめます。
ソルバーの基本的な仕様については [solver/README.md](../README.md) を参照してください。また、合成の検証と実行の意味については [docs/composition.md](../../docs/composition.md) にまとめています。

## 実装

| 言語 | パッケージ |
|---|---|
| Rust | crate `necoherence-composition-solver` |
| Lean | パッケージ `necoherence-composition-solver` |

どちらも探索を実装しています。

## 導入

各実装のうち Rust の crate は、`Cargo.toml` の `[dependencies]` に指定します。動作には Rust 1.88 以降が必要です。

```toml
[dependencies]
necoherence-composition-solver = "0.3.0"
```

## 入力

基本のパッケージの `semantic_composition::prepare_direct_composition` で、宣言のグラフと合成の問題から `PreparedCompositionInput` を作ります。
コード生成ツールに渡す JSON では、合成の問題は `composition.problem` に入っています。

## 探索

探索の関数 `composition_search::derive` は、準備した入力を受け取り、結果を返します。

- 準備した入力: `PreparedCompositionInput`
- 結果: `CompositionDecision`

結果に含まれる合成は、この crate の `verification::verify_composition` で検証済みです。得られた導出木を `composition.derivation` に指定すると、コード生成に使うことができます。

| 結果 | 内容 |
|---|---|
| `Solved` | 検証済みの合成と、その合成を選んだ根拠 |
| `Unreachable` | 候補が尽きたことを示す閉包の証拠 |
| `Incomplete` | 上限などで決まらなかった条件の一覧 |
| `Ambiguous` | 一つの合成を求めた場合に見つかった、二つ以上の異なる合成 |

## 使用例

利用方法の具体例は、[`solver/composition/rust/tests/composition_enumeration_snapshot.rs`](rust/tests/composition_enumeration_snapshot.rs) を参照してください。

## 検査

```sh
cd solver/composition/rust && cargo test
cd solver/composition/lean && lake build NecoherenceCompositionSolver
```

比較スクリプト `solver/composition/verification/check.py` で、Lean と Rust の照合と証拠の検証結果を比較できます。

## ライセンス

AGPL-3.0-only
