# Rust 向けの Necoherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

このクレートは、Necoherence の Rust による実装で、Rust 1.88 以降で使えます。

## 意味プロファイルの受け入れ

呼び出し側は、宣言を復号するときと、生成したライブラリを受け入れるときに、版の付いた意味プロファイルを渡します。
検証、符号化と復号、実行で使う転送形式は、受け入れたプロファイルが定めます。

`decode_value_profile` は文字列を受け取ります。
そのため呼び出し側は、信頼するバイト列と入力を照合してから、入力を UTF-8 として復号します。
期待する参照と出典の照合も、呼び出し側で行います。

```rust
use necoherence::exact_json::JsonValue;
use necoherence::semantic_exchange::decode_value_profile;
use necoherence::semantic_types::{ProfileRef, SourceIdentity, ValueDecision};
use necoherence::semantic_validation::accepts_value;
use necoherence::signature_admission::check_type_signatures;
use necoherence::type_signatures::{check_library, TypeSignatureLibrary};

fn decide(
    expected: &ProfileRef, sources: &[SourceIdentity], trusted: &[u8], input: &[u8],
    mut library: TypeSignatureLibrary, type_id: &str, value: &JsonValue,
) -> Result<ValueDecision, String> {
    if trusted != input { return Err("profile bytes differ".into()); }
    let text = std::str::from_utf8(input).map_err(|error| error.to_string())?;
    let profile = decode_value_profile(text).map_err(|error| error.to_string())?;
    if &profile.reference != expected || profile.source_refs != sources {
        return Err("profile basis differs".into());
    }
    library.profile = profile;
    check_library(&library).map_err(|error| format!("{error:?}"))?;
    let graph = check_type_signatures(&library).map_err(|error| error.to_string())?;
    let reference = &graph.nodes.iter()
        .find(|node| node.reference.definition_name.as_ref() == type_id)
        .ok_or("unknown type")?.reference;
    Ok(accepts_value(&graph, reference, value))
}
```

公開 API が返す失敗と判定の型は、次のとおりです。

- `GenerationFailure`: プロファイルの復号の失敗
- `LibraryCheckFailure`: ライブラリの検査の失敗
- `AdmissionFailure`: グラフの構築の失敗
- `ValueDecision`: 値の判定の結果
- `ValueFailure`: 拒否した値についての情報

## その他の機能

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) に挙げた機能のほかに、次の機能があります。

- 宣言の検査: 識別子の重複や、宣言にない型や定義への参照など、型と操作の宣言の誤りを検出する
- 生成したコードのランタイム: 生成した Rust のコードが実行時に呼び出す、値の検証とコーデックの共通の処理
- HTTP アダプター: 任意の `http-adapter` feature が、ネットワーク副作用のリクエストを `ureq` で実行し、結果を観測として返す

## 型付きの遷移モデル

モジュール `typed_mapping` は、ソルバーが探索するモデルを定義しています。
モデルは、場所、遷移、トークンから成ります。

- 場所、遷移、トークンのデータ型
- ソルバーへの入力の検証
- 遷移を 1 回適用する処理
- ソルバーが返す証拠の型 ( 到達、閉包、デッドロック、非循環 )

閉包は、到達できるすべての状態の集合です。

## 付属のツール

型と操作の宣言から Rust の型とコーデックを生成する生成器と、到達できる状態を探索するソルバーは、[tools/](https://github.com/barineco/necoherence/tree/publish/tools) にあります。
ライセンスは AGPL-3.0-only です。

## インストール

```bash
cargo add necoherence
```

既定の feature には、核のモデル、検証、コーデックが含まれます。
純粋な `network_effect` のモデルは、既定の feature で利用できます。
ネイティブの HTTP アダプターと、その通信の依存は、明示して有効にします。

```bash
cargo add necoherence --features http-adapter
```

WebAssembly で核を使う場合は、既定の feature のまま、次のコマンドでターゲットを検査します。

```bash
cargo check --lib --target wasm32-unknown-unknown --no-default-features
```

## 開発時の検査

次のコマンドで、フォーマットの検査、静的検査、テストを実行します。

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
cargo clippy --all-targets --features http-adapter -- -D warnings
cargo test --all-targets --features http-adapter
cargo check --lib --target wasm32-unknown-unknown --no-default-features
```

## ライセンス

[MIT](LICENSE)
