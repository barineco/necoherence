# Necoherence for Java

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This package is the Java implementation of Necoherence, for Java 21.
You build `build/necoherence-0.1.0.jar` from source and add the jar to the classpath.
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
    checked.valueContext().validate(0, value);
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
- HTTP adapter: executes the requests of the network effect with `java.net.http.HttpClient` and returns the results as observations

## Tools

The generator, which produces Java types and codecs from declarations of types and operations, is in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Its license is AGPL-3.0-only.

## Building and testing

The tests use JUnit Platform Console Standalone 1.10.2.
The following commands download this jar from Maven Central into `lib/`, check its SHA-256 digest, and then build, test, and package `build/necoherence-0.1.0.jar`:

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
jar --create --file build/necoherence-0.1.0.jar -C build/classes .
```

## License

[MIT](LICENSE)
