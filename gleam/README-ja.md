# Gleam 向けの Necoherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

このパッケージは、Necoherence の Gleam による実装で、Gleam 1.17 以降で使えます。
対応するのは Erlang ターゲットだけです。
動作は、OTP 27 と Gleam 1.18.1 ( CI で使う版 ) で確認しています。

## 意味プロファイルの受け入れ

呼び出し側は、宣言を復号するときと、生成したライブラリを受け入れるときに、版の付いた意味プロファイルを渡します。
検証、符号化と復号、実行で使う転送形式は、受け入れたプロファイルが定めます。

呼び出し側は、信頼する文字列、期待する参照、出典を照合してから、ライブラリを受け入れます。
受け入れたライブラリは、値の判定に使えます。

- `decode_library`: ライブラリの受け入れ
- `check_library`: 受け入れるときの条件の検査
- `AdmittedLibrary`: 受け入れたライブラリの型
- `validate_value`: 値の判定

```gleam
import gleam/bit_array
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures

pub fn decide(expected, sources, trusted, input, library_wire, value) {
  let assert True = trusted == input
  let assert Ok(input_text) = bit_array.to_string(input)
  let assert Ok(profile_json) = values.parse_wire(input_text)
  let assert Ok(profile) = decode.decode_semantic_profile(profile_json)
  let assert True = profile.reference == expected
  let assert True = profile.source_refs == sources
  let assert Ok(library) = signatures.decode_library(library_wire)
  let assert True = signatures.library_graph(library).profile == profile
  signatures.validate_value(library, "unit", value)
}
```

失敗の型は、原因ごとに次のとおりです。

- `ValueCodecFailure`: プロファイルの JSON の復号の失敗
- `DecodeFailure`: プロファイルの宣言の復号の失敗
- `semantic_signatures.Failure`: ライブラリの受け入れの失敗
- `LibraryCheckFailure`: 受け入れるライブラリが条件に違反している
- `semantic_generation_runtime.ValueFailure`: 値が検証で拒否された

## その他の機能

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) に挙げた機能のほかに、次の機能があります。

- 宣言の検査: 識別子の重複や、宣言にない型や定義への参照など、型と操作の宣言の誤りを検出する
- 生成したコードのランタイム: 生成した Gleam のコードが実行時に呼び出す、値の検証とコーデックの共通の処理

任意の [HTTP アダプター](../gleam-http-adapter/) は、独立したパッケージでネットワーク副作用のコマンドを実行します。

- アダプターの HTTP クライアント: `gleam_httpc`

## 型付きの遷移モデル

モジュール `typed_mapping` は、ソルバーが探索するモデルを定義しています。
モデルは、場所、遷移、トークンから成ります。

- 場所、遷移、トークンのデータ型
- ソルバーへの入力の検証
- 遷移を 1 回適用する処理
- ソルバーが返す証拠の型 ( 到達、閉包、デッドロック、非循環 )

閉包は、到達できるすべての状態の集合です。

## 付属のツール

型と操作の宣言から Gleam の型とコーデックを生成する生成器と、到達できる状態を探索するソルバーは、[tools/](https://github.com/barineco/necoherence/tree/publish/tools) にあります。
ライセンスは AGPL-3.0-only です。

## 生成したコードの初期化

生成を識別するために、パッケージが提供する関数は次の 2 つです。

```gleam
semantic_signatures.generation_requirement(checked: CheckedGeneration) -> GenerationRequirement
semantic_signatures.require_generation(required: GenerationRequirement, checked: CheckedGeneration) -> Result(CheckedGeneration, GenerationMismatch)
```

`generation_requirement` は、受け入れた生成値から、9 つの項目から成る型付きの生成要件を取り出します。
`require_generation` は、生成要件と検査済みの生成値を照合し、食い違いをすべて返します。

生成したモジュールが持つ初期化関数の形は、次のとおりです。

```gleam
initialize(checked: CheckedGeneration) -> Result(Context, GenerationMismatch)
```

`Context` は、初期化関数が返す文脈の型です。
初期化に成功すると、文脈は呼び出し側が受け入れた生成値を保持し、生成した値、コーデック、操作に渡す入力になります。

## インストール

```bash
gleam add necoherence
```

## 開発時の検査

次のコマンドで、フォーマットの検査、ビルド、テストを実行します。

```bash
gleam format --check
gleam build --warnings-as-errors
gleam test
```

## ライセンス

[MIT](LICENSE)
