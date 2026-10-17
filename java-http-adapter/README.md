# Necoherence HTTP adapter for Java

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This optional MIT jar executes Necoherence network-effect commands with `java.net.http.HttpClient`.
It requires Java 21 and the core `necoherence-0.2.0.jar` on the classpath.
The core jar contains the ledger and the `SemanticValues.HostAdapter` port.

Build the core jar following [the Java README](../java/README.md), then build this adapter separately:

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

Add both jars to the application's classpath and construct `necoherence.network.JavaHttpAdapter` explicitly.
Its `semanticPort()` method supplies the core's `SemanticValues.HostAdapter` interface to generated operations.

[MIT License](LICENSE)
