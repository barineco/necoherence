# Lean 4 向けの Necoherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

このパッケージは、Necoherence の Lean 4 による実装です。
[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) に挙げた機能を、実行できる定義として書いており、他の言語の実装はこの定義を仕様として扱います。
ビルドには、Lean のツールチェーン v4.32.1 を使います。

呼び出し側は、宣言を検査するときと、生成したライブラリを受け入れるときに、`VersionedSemanticProfile` を渡します。検証、射影、実行で使う転送形式のキーは、すべてこのプロファイルにあるラッパー、タグ、閉じた形の宣言から決まります。プロファイルとライブラリは、使う前に検査されます。

## 宣言の検査

宣言の検査には、次の内容が含まれます。

- 型と操作の宣言が満たす条件
- 検査を通った宣言の集合で、参照する型がすべて宣言されていることを示す定理
- 操作を拡張しても、元の結果が保たれることを示す定理
- 生成した Lean のコードが使う定義

## 型付きの遷移モデル

`Necoherence.TypedMapping` は、ソルバーが探索するモデルを定義しています。モデルは、場所、遷移、トークンから成ります。

- 場所、遷移、トークンのデータ型
- ソルバーへの入力の検証
- 遷移を 1 回適用する処理と、与えた遷移の列を順に適用する経路の再生
- ソルバーが返す証拠の型 ( 到達、閉包、デッドロック、非循環 )
- 不正な入力について報告する理由が実際に成り立つことと、経路の再生が遷移の関係と一致することを示す定理

閉包は、到達できるすべての状態の集合です。

## 残余の整合性

この部分には、残余量の有限モデルと、どのモデルでも成り立つ定理 ( 残余量が 0 以上であることなど ) が含まれます。残余量とは、導いた点のうち宣言にない点が、測度に寄与する量の合計です。

## ネットワーク副作用の実行ファイル

`network_effect_runner` は、標準入力から JSON のリクエストを 1 件読み取り、結果を JSON で出力する実行ファイルです ( [リクエストの形式](https://github.com/barineco/necoherence/blob/publish/lean/Necoherence/NetworkEffectRunner.lean) ) 。他の言語の実装の出力は、この出力と照合しています。

## 付属のツール

Lean のコードを生成する生成器と、ソルバーは [tools/](https://github.com/barineco/necoherence/tree/publish/tools) にあります。
ライセンスは AGPL-3.0-only です。
残余の整合性の検証器は [residual-coherence](https://github.com/barineco/necoherence/tree/publish/residual-coherence) にあります。

## ビルドと実行

次のコマンドで、ビルド ( 定理の検査を含む ) 、残余の整合性の定理の数値による確認、`network_effect_runner` の実行を行います。

```bash
lake build
lake env lean Tests/ResidualCoherenceTheorems.lean
lake exe network_effect_runner < request.json
```

## ライセンス

[MIT](LICENSE)
