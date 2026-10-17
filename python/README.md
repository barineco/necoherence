# Necoherence for Python

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This package is the Python implementation of Necoherence, for Python 3.12 or later.
It uses only the standard library at run time.

## Accepting a semantic profile

The caller passes a versioned semantic profile when decoding declarations and when accepting a generated library.
The accepted profile defines the wire format used by validation, encoding and decoding, and execution.

The expected profile reference, the sources, and the trusted bytes are passed as arguments separate from the input bytes.

```python
from necoherence.signature_values import ValueContext
from necoherence.type_signatures import checkLibrary, decode_profile_artifact

def decide(expected, sources, trusted, input_bytes, library, type_id, value):
    profile = decode_profile_artifact(expected, sources, trusted, input_bytes)
    checked = checkLibrary({**library, "profile": profile})
    context = ValueContext({
        "profile": checked.value["profile"], "nodes": checked.value["nodes"],
    })
    return context.validate(type_id, value)
```

Failures are returned as the following types, one for each cause:

- `WireFailure`: the profile's wire value is malformed
- `DeclarationFailure`: the profile or the library violates a declaration condition
- `AdmissionFailure`: the profile differs from the expected reference or sources
- `MeaningFailure`: a type lacks a definition of its meaning
- `ValueFailure`: validation rejected the value

## Other features

Besides the features listed in the [project overview](https://github.com/barineco/necoherence/blob/publish/README.md), the package provides the following:

- Declaration checking: detects errors in declarations of types and operations, such as duplicate identifiers and references to undeclared types or definitions
- Runtime for generated code: the shared value validation and codec routines that generated Python code calls at run time

The optional [HTTP adapter](../python-http-adapter/) is distributed separately as `necoherence-http-adapter`. It executes network-effect commands and returns observations to the core ledger.

## Tools

The generator, which produces Python types and codecs from declarations of types and operations, is in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Its license is AGPL-3.0-only.

## Examples

Examples are in [examples/](https://github.com/barineco/necoherence/tree/publish/python/examples).

## Testing and type checking

The following commands run the tests and the type checks:

```bash
python3 -m pip install ".[dev]"
python3 -m pytest -q
python3 -m mypy src tests
```

## License

[MIT](LICENSE)
