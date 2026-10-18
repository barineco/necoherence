# Java 向けの Necoherence の HTTP アダプター

[プロジェクトの概要](https://github.com/barineco/necoherence/blob/publish/README-ja.md) | [English](README.md)

この任意の jar は、Necoherence のネットワーク副作用のコマンドを `java.net.http.HttpClient` で実行します。ライセンスは MIT です。
Java 21 と、クラスパス上の核の `necoherence-0.2.1.jar` が必要です。
核の jar は、台帳と `SemanticValues.HostAdapter` のポートを持ちます。

## Maven の座標と公開のビルド

座標は `io.github.barineco:necoherence-http-adapter:0.2.1` です。
POM は、同じ版の核に依存します。

2 つの公開物のビルドは、JDK 21 を `PATH` に置いてリポジトリの root で行う手順です。

```sh
scripts/build-maven.sh build
```

公開物ごとの 4 つのファイルは、次のディレクトリに書き出されます。

```text
java/build/maven/io/github/barineco/<artifactId>/0.2.1/
```

署名と bundle の段は、GPG を設定し、鍵の ID を環境変数 `NECOHERENCE_GPG_KEY` に入れてから実行する手順です。

```sh
scripts/build-maven.sh bundle
```

この段は署名とチェックサムを書き出し、upload 用の zip を `java/build/maven/` に組み立てます。
Maven Central へのアップロードは別の手作業の段で、前提の条件、再現性、出力先の指定は [Java の公開の手順](../java/README-ja.md#maven-central-の公開物) にあります。

## テスト

ビルドの後に、`java-http-adapter/` で次のコマンドを実行します。

```sh
mkdir -p build/test-classes
core=../java/build/maven/io/github/barineco/necoherence/0.2.1/necoherence-0.2.1.jar
adapter=../java/build/maven/io/github/barineco/necoherence-http-adapter/0.2.1/necoherence-http-adapter-0.2.1.jar
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac --release 21 -cp "$core:$adapter" -d build/test-classes
for test in NetworkEffectHttpSmoke NetworkEffectProgressionSmoke; do
  java -cp "$core:$adapter:build/test-classes" "necoherence.network.$test"
done
```

アプリケーションのクラスパスに 2 つの jar を加え、`necoherence.network.JavaHttpAdapter` を明示して構築します。
そのメソッド `semanticPort()` が生成した操作へ渡すのは、核のインターフェース `SemanticValues.HostAdapter` です。

[MIT ライセンス](LICENSE)
