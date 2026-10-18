# Necoherence for Java

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This package is the Java implementation of Necoherence, for Java 21.
The Maven coordinates are `io.github.barineco:necoherence:0.2.1`.
You can also build the jar from source and add it to the classpath.
It depends only on the JDK.

## Accepting a semantic profile

The caller passes a versioned semantic profile when decoding declarations and when accepting a generated library.
The accepted profile defines the wire format used by validation, encoding and decoding, and execution.

The expected profile reference, the sources, and the trusted bytes are passed as arguments separate from the input bytes.

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

Failures are returned as the following types, one for each cause:

- `GenerationFailure`: accepting the profile, the library, or the generated code failed
- `ValueFailure`: validation rejected the value

## Other features

Besides the features listed in the [project overview](https://github.com/barineco/necoherence/blob/publish/README.md), the package provides the following:

- Declaration checking: detects errors in declarations of types and operations, such as duplicate identifiers and references to undeclared types or definitions
- Runtime for generated code: the shared value validation and codec routines that generated Java code calls at run time

The optional [HTTP adapter](../java-http-adapter/) executes network-effect commands in a separate jar.

- Adapter's HTTP client: `java.net.http.HttpClient`

## Tools

The generator, which produces Java types and codecs from declarations of types and operations, is in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Its license is AGPL-3.0-only.

## Building and testing

The tests use JUnit Platform Console Standalone 1.10.2.
From `java/`, the following commands download the test runner from Maven Central into `lib/`, check its SHA-256 digest, build both release artifacts, and run the core tests:

```bash
../scripts/build-maven.sh build
mkdir -p lib build/test-classes
curl --fail --location --silent --show-error \
  --output lib/junit-platform-console-standalone-1.10.2.jar \
  https://repo1.maven.org/maven2/org/junit/platform/junit-platform-console-standalone/1.10.2/junit-platform-console-standalone-1.10.2.jar
printf '%s  %s\n' \
  a1de557821293ce903c213c694165fff532cf92081bac4238b9e05b35f04f43f \
  lib/junit-platform-console-standalone-1.10.2.jar | shasum -a 256 -c -
find src/test/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 \
      -cp "build/maven/io/github/barineco/necoherence/0.2.1/necoherence-0.2.1.jar:lib/junit-platform-console-standalone-1.10.2.jar" \
      -d build/test-classes
java -Duser.language=en -jar lib/junit-platform-console-standalone-1.10.2.jar execute \
  --class-path build/maven/io/github/barineco/necoherence/0.2.1/necoherence-0.2.1.jar:build/test-classes --scan-class-path
```

## Maven Central release artifacts

From the repository root with JDK 21 on `PATH`:

```sh
scripts/build-maven.sh build
# Or select a new, caller-owned output directory:
# scripts/build-maven.sh build /path/to/new-output
```

The default output directory is `java/build/maven/`, which Git ignores.
The script requires a new output directory.
For each of the core and the adapter, it writes four files under `io/github/barineco/<artifactId>/0.2.1/`:

- the binary jar
- the sources jar
- the Javadoc jar
- the POM

The build needs JDK 21 and standard POSIX shell utilities.
Sources and jar entries are sorted, jar timestamps are fixed, and Javadoc output carries no timestamps, so the same JDK 21 build reproduces the same files.
Javadoc validation runs during the build and reports missing comments as warnings.

Signing is a separate, explicit release operation, never part of building or tests.
With a signing key already configured in GPG, set `NECOHERENCE_GPG_KEY` to its key id:

```sh
scripts/build-maven.sh bundle
# With a custom build directory, pass that same directory:
# scripts/build-maven.sh bundle /path/to/new-output
```

For each jar and POM, this step signs the file with GPG and writes the signature and the MD5 and SHA-1 checksums next to it.
It then creates `central-bundle-0.2.1.zip` in the output directory.
The step requires GPG, OpenSSL, and `zip`.
The key stays in the local GPG keyring, and the upload to Maven Central is a separate manual step.
The zip follows the [Central Portal bundle layout](https://central.sonatype.org/publish/publish-portal-upload/)
and [artifact requirements](https://central.sonatype.org/publish/requirements/).

## License

[MIT](LICENSE)
