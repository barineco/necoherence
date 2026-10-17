# Java 向けの Necoherence

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

このパッケージは、Necoherence の Java による実装で、Java 21 で使えます。
ソースから `build/necoherence-0.2.0.jar` をビルドし、その jar をクラスパスに加えて使います。
依存するのは JDK だけです。

## 意味プロファイルの受け入れ

呼び出し側は、宣言を復号するときと、生成したライブラリを受け入れるときに、版の付いた意味プロファイルを渡します。
検証、符号化と復号、実行で使う転送形式は、受け入れたプロファイルが定めます。

期待するプロファイルの参照、出典、信頼するバイト列は、入力のバイト列とは別の引数として渡します。

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
    GenerationBasis expectedBasis = GenerationBasis.decode(encodeWire(basis));
    WireValue exchange = obj("schema", str("ncoh-checked-generation@4"),
        "basis", basis, "signatures", library, "composition", NIL, "entrypoints", entries);
    CheckedGeneration checked = TypeSignatures.admitGeneration(expectedBasis, encodeWire(exchange));
    checked.valueContext().validate(TypeSignatures.typeReference("root"), value);
    return value;
}
```

失敗の型は、原因ごとに次のとおりです。

- `GenerationFailure`: プロファイル、ライブラリ、生成物のいずれかの受け入れに失敗した
- `ValueFailure`: 値が検証で拒否された

## その他の機能

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) に挙げた機能のほかに、次の機能があります。

- 宣言の検査: 識別子の重複や、宣言にない型や定義への参照など、型と操作の宣言の誤りを検出する
- 生成したコードのランタイム: 生成した Java のコードが実行時に呼び出す、値の検証とコーデックの共通の処理

任意の [HTTP アダプター](../java-http-adapter/) は、独立した jar でネットワーク副作用のコマンドを実行します。

- アダプターの HTTP クライアント: `java.net.http.HttpClient`

## 付属のツール

型と操作の宣言から Java の型とコーデックを生成する生成器は、[tools/](https://github.com/barineco/necoherence/tree/publish/tools) にあります。
ライセンスは AGPL-3.0-only です。

## ビルドとテスト

テストには、JUnit Platform Console Standalone 1.10.2 を使います。
次のコマンドで、この jar を Maven Central から `lib/` へ取得し、SHA-256 のダイジェストを確かめてから、ビルド、テスト、`build/necoherence-0.2.0.jar` の作成までを行います。

```bash
mkdir -p lib build/classes build/test-classes
curl --fail --location --silent --show-error \
  --output lib/junit-platform-console-standalone-1.10.2.jar \
  https://repo1.maven.org/maven2/org/junit/platform/junit-platform-console-standalone/1.10.2/junit-platform-console-standalone-1.10.2.jar
printf '%s  %s\n' \
  a1de557821293ce903c213c694165fff532cf92081bac4238b9e05b35f04f43f \
  lib/junit-platform-console-standalone-1.10.2.jar | shasum -a 256 -c -
find src/main/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 -d build/classes
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 \
      -cp "build/classes:lib/junit-platform-console-standalone-1.10.2.jar" \
      -d build/test-classes
java -Duser.language=en -jar lib/junit-platform-console-standalone-1.10.2.jar execute \
  --class-path build/classes:build/test-classes --scan-class-path
jar --create --file build/necoherence-0.2.0.jar -C build/classes .
```

## ライセンス

[MIT](LICENSE)
