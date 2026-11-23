# Necoherence (Java)

[プロジェクトの概要](../../../README.md)

このパッケージは、Necoherence の Java 実装です。

- Java 21
- 実行時の依存関係は `neco-quotient` のみ

公開先の Maven 座標は `io.github.barineco:necoherence:0.3.0` です。ソースから JAR ファイルをビルドしてクラスパスに追加して使用できます。

## 検証結果

値の検証結果は、「確定」「残余」「停止」「失敗」に分類されます。分類の判定順序については [docs/terminology.md](../../../docs/terminology.md#確定残余停止失敗) を参照してください。本実装では、次のメソッドで結果を分類します。

- `SemanticTypes.classifyValueDecision`: 分類済みの実行時判定結果

## 残余の記録

クラス `necoherence.semantic.SemanticResidualRecord` は、値の検証が返した残余を、`neco-quotient` の正規のバイト列として書き出します。記録は `schema`、`basis`、入力、義務の列の 4 つのフィールドを持ち、各フィールドの通信形式は既存の宣言の通信形式と同じです。

- `SemanticResidualRecord.encodeSemanticResidual`: 生成の `basis`、型の参照、値、義務の列から、正規のバイト列を作る。義務の列は順序と重複によらず同じバイト列になる

結果は `neco-quotient` の `Result` で返ります。符号化の失敗時は、`neco-quotient` が返した失敗の値がそのまま保たれます。

## データモデル宣言

仕様と照合の条件については、[docs/data-model.md](../../../docs/data-model.md) を参照してください。

期待するデータモデル宣言の参照識別子、出典、信頼できるバイト列は、入力バイト列とは独立した引数として渡します。

```java
import java.util.List;
import necoherence.semantic.SemanticGeneration.CheckedGeneration;
import necoherence.semantic.SemanticGeneration.GenerationBasis;
import necoherence.semantic.SemanticValues.WireValue;
import necoherence.semantic.TypeSignatures;
import static necoherence.semantic.SemanticValues.*;

static WireValue decide(WireValue expected, List<WireValue> sources,
        byte[] trusted, byte[] input, WireValue library, WireValue value) throws Exception {
    WireValue profile = TypeSignatures.admitCanonicalProfile(expected, sources, trusted, input);
    library = TypeSignatures.replace(library, "profile", profile);
    TypeSignatures.checkLibrary(library);
    WireValue entries = arr(List.of(obj("identity", str("root"), "definition", str("root"))));
    WireValue basis = TypeSignatures.computeBasis(library, entries, NIL);
    GenerationBasis expectedBasis = GenerationBasis.decode(encodeWire(obj("basis", basis, "observations", NIL)));
    WireValue exchange = obj("schema", str("ncoh-checked-generation@5"),
        "basis", basis, "signatures", library, "composition", NIL, "entrypoints", entries);
    CheckedGeneration checked = TypeSignatures.admitGeneration(expectedBasis, encodeWire(exchange));
    checked.valueContext().validate(TypeSignatures.typeReference("root"), value);
    return value;
}
```

主なエラー型とその要因:

- `GenerationFailure`: データモデル宣言、ライブラリ、生成アーティファクトのいずれかの照合または妥当性検証に失敗
- `SemanticValues.ValueRejection`: 値が型制約の検証で拒否された

## その他の機能

[プロジェクトの概要](../../../README.md) に記載の機能に加え、次の機能を提供します。

- 宣言の検証: 識別子の重複や未定義の型・定義への参照など、型や操作の宣言エラーを静的に検出
- 生成コード用ランタイム: 生成された Java コードが実行時に呼び出す、値検証およびコーデックの共通処理

ネットワーク副作用コマンドを HTTP 経由で実行する場合は、[`http/`](http/) の HTTP アダプターを使用します。

## コード生成の受け入れ

形式 `ncoh-checked-generation@5` の JSON を受け入れる関数:

- `basis` の計算: `necoherence.semantic.TypeSignatures.basis`
- 受け入れ検証: `necoherence.semantic.TypeSignatures.admitGeneration`

生成識別値 `basis` と受け入れ検証の規則は [docs/generation.md](../../../docs/generation.md) を参照してください。

## 合成の実行

検証を通過した合成を実行する関数:

- 実行の開始: `necoherence.composition.SemanticExecution.start`
- 実行の再開: `necoherence.composition.SemanticExecution.resume`

実行の開始には `AdmittedComposition` を渡します。これは受け入れ検証の結果 ( `CheckedGeneration` ) の `composition()` から取得します。

実行の入力、関数の実装、進捗状態の意味は [docs/composition.md](../../../docs/composition.md#合成の実行) を参照してください。

## 付属のツール

型と操作の宣言から Java の型定義とコーデックを生成するコード生成ツールは、[generator/](../../../generator/) 配下にあります。ライセンスは AGPL-3.0-only です。

## ビルドとテスト

テストの実行には JUnit Platform Console Standalone 1.10.2 を使用します。
ディレクトリ `packages/java/adapter/` で以下のコマンドを実行すると、Maven Central からテストランナーを `lib/` へダウンロードして SHA-256 チェックサムを照合し、コアパッケージおよびアダプターの JAR をビルドしてテストを実行します。

```bash
../build-maven.sh build
mkdir -p lib build/test-classes
curl --fail --location --silent --show-error \
  --output lib/junit-platform-console-standalone-1.10.2.jar \
  https://repo1.maven.org/maven2/org/junit/platform/junit-platform-console-standalone/1.10.2/junit-platform-console-standalone-1.10.2.jar
printf '%s  %s\n' \
  a1de557821293ce903c213c694165fff532cf92081bac4238b9e05b35f04f43f \
  lib/junit-platform-console-standalone-1.10.2.jar | shasum -a 256 -c -
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 \
      -cp "build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar:lib/junit-platform-console-standalone-1.10.2.jar" \
      -d build/test-classes
java -Duser.language=en -jar lib/junit-platform-console-standalone-1.10.2.jar execute \
  --class-path build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar:build/test-classes --scan-class-path
```

## ライセンス

[MIT](LICENSE)
