# Necoherence HTTP adapter for Java

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This optional MIT jar executes Necoherence network-effect commands with `java.net.http.HttpClient`.
It requires Java 21 and the core `necoherence-0.2.2.jar` on the classpath.
The core jar contains the ledger and the `SemanticValues.HostAdapter` port.

## Maven coordinates and release build

Use `io.github.barineco:necoherence-http-adapter:0.2.2`.
Its POM depends on `io.github.barineco:necoherence:0.2.2`.

From the repository root with JDK 21 on `PATH`, build both artifacts:

```sh
scripts/build-maven.sh build
```

Each artifact's jar, sources jar, Javadoc jar, and POM are written under
`java/build/maven/io/github/barineco/<artifactId>/0.2.2/`.
For an explicit signing and bundle step, configure GPG, export
`NECOHERENCE_GPG_KEY` with the key id, and run:

```sh
scripts/build-maven.sh bundle
```

This writes signatures and MD5/SHA-1 checksums and assembles
`java/build/maven/central-bundle-0.2.2.zip`; the upload to Maven Central is a separate manual step.
See [the Java release instructions](../java/README.md#maven-central-release-artifacts)
for prerequisites, reproducibility, and custom output directories.

## Testing

After building, run these commands from `java-http-adapter/`:

```sh
mkdir -p build/test-classes
core=../java/build/maven/io/github/barineco/necoherence/0.2.2/necoherence-0.2.2.jar
adapter=../java/build/maven/io/github/barineco/necoherence-http-adapter/0.2.2/necoherence-http-adapter-0.2.2.jar
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac --release 21 -cp "$core:$adapter" -d build/test-classes
for test in NetworkEffectHttpSmoke NetworkEffectProgressionSmoke; do
  java -cp "$core:$adapter:build/test-classes" "necoherence.network.$test"
done
```

Add both jars to the application's classpath and construct `necoherence.network.JavaHttpAdapter` explicitly.
Its `semanticPort()` method supplies the core's `SemanticValues.HostAdapter` interface to generated operations.

[MIT License](LICENSE)
