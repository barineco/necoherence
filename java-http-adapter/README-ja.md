# Java 向けの Necoherence の HTTP アダプター

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

この任意の jar は、Necoherence のネットワーク副作用のコマンドを `java.net.http.HttpClient` で実行します。ライセンスは MIT です。
Java 21 と、クラスパス上の核の `necoherence-0.2.0.jar` が必要です。
核の jar は、台帳と `SemanticValues.HostAdapter` のポートを持ちます。

[Java の README](../java/README-ja.md) の手順で核の jar をビルドしてから、このアダプターを別にビルドします。

```bash
mkdir -p build/classes build/test-classes
find src/main/java -name '*.java' -print0 \
  | xargs -0 javac --release 21 -cp ../java/build/necoherence-0.2.0.jar -d build/classes
jar --create --file build/necoherence-http-adapter-0.2.0.jar -C build/classes .
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac --release 21 -cp ../java/build/necoherence-0.2.0.jar:build/classes -d build/test-classes
for test in NetworkEffectHttpSmoke NetworkEffectProgressionSmoke; do
  java -cp ../java/build/necoherence-0.2.0.jar:build/classes:build/test-classes "necoherence.network.$test"
done
```

アプリケーションのクラスパスに 2 つの jar を加え、`necoherence.network.JavaHttpAdapter` を明示して構築します。
そのメソッド `semanticPort()` が生成した操作へ渡すのは、核のインターフェース `SemanticValues.HostAdapter` です。

[MIT ライセンス](LICENSE)
