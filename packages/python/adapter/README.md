# Necoherence (Python)

[プロジェクトの概要](../../../README.md)

このパッケージは、Necoherence の Python 実装です。

- Python 3.14 以降

実行時の依存関係は次の 4 パッケージです。

- `neco-quotient-certificate`
- `neco-quotient-application`
- `neco-quotient-retention`
- `neco-quotient-encoding`

## 検証結果

値の検証結果は、「確定」「残余」「停止」「失敗」に分類されます。分類の判定順序については [docs/terminology.md](../../../docs/terminology.md#確定残余停止失敗) を参照してください。本実装では、次の関数で結果を分類します。

- `signature_values.classify_semantic_obligations`: 値の検証で未解決となった理由の分類
- `signature_support.classify_unresolved_obligations`: 合成処理で未解決となった理由の分類

## データモデル宣言

仕様と照合の条件については、[docs/data-model.md](../../../docs/data-model.md) を参照してください。

期待するデータモデル宣言の参照識別子、出典、信頼できるバイト列は、入力バイト列とは独立した引数として渡します。

```python
from necoherence.type_signatures import (
    ExpectedSignatureBasis,
    admit_signature_generation,
    decode_profile_artifact,
    signature_basis,
)

def decide(expected, sources, trusted, input_bytes, library, entrypoints, type_id, value):
    profile = decode_profile_artifact(expected, sources, trusted, input_bytes)
    signatures = {**library, "profile": profile}
    basis = signature_basis(signatures, entrypoints)
    exchange = {
        "schema": "ncoh-checked-generation@5",
        "basis": basis,
        "signatures": signatures,
        "composition": None,
        "entrypoints": entrypoints,
    }
    checked = admit_signature_generation(ExpectedSignatureBasis(basis, None), exchange)
    return checked.values.validate(type_id, value)
```

主なエラー型とその要因:

- `WireFailure`: データモデル宣言のワイヤ転送形式が不正
- `DeclarationFailure`: データモデル宣言またはライブラリが宣言規則に違反している
- `AdmissionFailure`: データモデル宣言の参照や出典が期待値と不一致
- `MeaningFailure`: 型の解釈に必要な定義がデータモデル宣言に不足している
- `ValueFailure`: 値が型制約の検証で拒否された

## その他の機能

[プロジェクトの概要](../../../README.md) に記載の機能に加え、次の機能を提供します。

- 宣言の検証: 識別子の重複や未定義の型・定義への参照など、型や操作の宣言エラーを静的に検出
- 生成コード用ランタイム: 生成された Python コードが実行時に呼び出す、値検証およびコーデックの共通処理

ネットワーク副作用コマンドを HTTP 経由で実行する場合は、[`http/`](http/) の HTTP アダプターを使用します。

## コード生成の受け入れ

形式 `ncoh-checked-generation@5` の JSON を受け入れる関数:

- `basis` の計算: `necoherence.type_signatures.signature_basis`
- 受け入れ検証: `necoherence.type_signatures.admit_signature_generation`

生成識別値 `basis` と受け入れ検証の規則は [docs/generation.md](../../../docs/generation.md) を参照してください。

## 残余の書き出し

関数 `necoherence.semantic_residual_record.encode_semantic_residual` は、値の検証が返した未解決の義務を、`neco-quotient` の正規のバイト列として書き出します。引数として生成の `basis`、型の参照、値、義務の列を受け取ります。記録は `schema`、`basis`、入力、義務の列の 4 つのフィールドを持ち、各フィールドの通信形式は既存の宣言の通信形式と同じです。義務の列は順序と重複によらず同じバイト列になります。

符号化の失敗時は、`neco-quotient` の失敗情報を含む `SemanticResidualFailure` 例外が発生します。

## 合成の実行

検証を通過した合成を実行する関数:

- 実行の開始: `necoherence.semantic_execution.start`
- 実行の再開: `necoherence.semantic_execution.resume`

実行の開始には `AdmittedComposition` を渡します。これは受け入れ検証の結果 ( `CheckedSignatureGeneration` ) の `admitted_composition` から取得します。

実行の入力、関数の実装、進捗状態の意味は [docs/composition.md](../../../docs/composition.md#合成の実行) を参照してください。

## 付属のツール

型と操作の宣言から Python の型定義とコーデックを生成するコード生成ツールは、[generator/](../../../generator/) 配下にあります。ライセンスは AGPL-3.0-only です。

## 使用例

具体的な使用例は [examples/](examples/) にあります。

## 開発時

次のコマンドでテストおよび型検査を実行できます。

```bash
python3 -m pip install ".[dev]"
python3 -m pytest -q
python3 -m mypy src tests
```

## ライセンス

[MIT](LICENSE)
