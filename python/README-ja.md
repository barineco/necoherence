# Python 向けの Necoherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

このパッケージは、Necoherence の Python による実装で、Python 3.12 以降で使えます。
実行時に使うのは、標準ライブラリだけです。

## 意味プロファイルの受け入れ

呼び出し側は、宣言を復号するときと、生成したライブラリを受け入れるときに、版の付いた意味プロファイルを渡します。
検証、符号化と復号、実行で使う転送形式は、受け入れたプロファイルが定めます。

期待するプロファイルの参照、出典、信頼するバイト列は、入力のバイト列とは別の引数として渡します。

```python
from necoherence.signature_values import ValueContext
from necoherence.type_signatures import checkLibrary, decode_profile_artifact

def decide(expected, sources, trusted, input_bytes, library, type_id, value):
    profile = decode_profile_artifact(expected, sources, trusted, input_bytes)
    checked = checkLibrary({**library, "profile": profile})
    context = ValueContext({
        "profile": checked.value["profile"], "nodes": checked.value["nodes"],
    })
    return context.validate(type_id, value)
```

失敗の型は、原因ごとに次のとおりです。

- `WireFailure`: プロファイルの転送値の形式が誤っている
- `DeclarationFailure`: プロファイルかライブラリが、宣言の条件に違反している
- `AdmissionFailure`: プロファイルが、期待した参照や出典と食い違っている
- `MeaningFailure`: 型に意味の定義が欠けている
- `ValueFailure`: 値が検証で拒否された

## その他の機能

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) に挙げた機能のほかに、次の機能があります。

- 宣言の検査: 識別子の重複や、宣言にない型や定義への参照など、型と操作の宣言の誤りを検出する
- 生成したコードのランタイム: 生成した Python のコードが実行時に呼び出す、値の検証とコーデックの共通の処理
- HTTP アダプター: ネットワーク副作用のリクエストを実行し、結果を観測として返す

## 付属のツール

型と操作の宣言から Python の型とコーデックを生成する生成器は、[tools/](https://github.com/barineco/necoherence/tree/publish/tools) にあります。
ライセンスは AGPL-3.0-only です。

## 使用例

使用例は [examples/](https://github.com/barineco/necoherence/tree/publish/python/examples) にあります。

## テストと型検査

次のコマンドで、テストと型検査を実行します。

```bash
python3 -m pip install ".[dev]"
python3 -m pytest -q
python3 -m mypy src tests
```

## ライセンス

[MIT](LICENSE)
