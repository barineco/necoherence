# Necoherence for Gleam

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This package is the Gleam implementation of Necoherence, for Gleam 1.17 or later.
It supports only the Erlang target.
It is verified on OTP 27 and Gleam 1.18.1 (the versions used in CI).

## Accepting a semantic profile

The caller passes a versioned semantic profile when decoding declarations and when accepting a generated library.
The accepted profile defines the wire format used by validation, encoding and decoding, and execution.

The caller checks the trusted text, the expected reference, and the sources before accepting the library.
The accepted library can then be used to decide on values.

- `decode_library`: accepting a library
- `check_library`: the condition check performed on acceptance
- `AdmittedLibrary`: the type of an accepted library
- `validate_value`: deciding on a value

```gleam
import gleam/bit_array
import necoherence/semantic_generation_decode as decode
import necoherence/semantic_generation_values as values
import necoherence/semantic_signatures as signatures

pub fn decide(expected, sources, trusted, input, library_wire, value) {
  let assert True = trusted == input
  let assert Ok(input_text) = bit_array.to_string(input)
  let assert Ok(profile_json) = values.parse_wire(input_text)
  let assert Ok(profile) = decode.decode_semantic_profile(profile_json)
  let assert True = profile.reference == expected
  let assert True = profile.source_refs == sources
  let assert Ok(library) = signatures.decode_library(library_wire)
  let assert True = signatures.library_graph(library).profile == profile
  signatures.validate_value(library, "unit", value)
}
```

Failures are returned as the following types, one for each cause:

- `ValueCodecFailure`: decoding the profile JSON failed
- `DecodeFailure`: decoding the profile declarations failed
- `semantic_signatures.Failure`: accepting the library failed
- `LibraryCheckFailure`: the library being accepted violates a condition
- `semantic_generation_runtime.ValueFailure`: validation rejected the value

## Other features

Besides the features listed in the [project overview](https://github.com/barineco/necoherence/blob/publish/README.md), the package provides the following:

- Declaration checking: detects errors in declarations of types and operations, such as duplicate identifiers and references to undeclared types or definitions
- Runtime for generated code: the shared value validation and codec routines that generated Gleam code calls at run time
- HTTP adapter: executes the requests of the network effect with `gleam_httpc` and returns the results as observations

## Typed transition model

The `typed_mapping` module defines the model that the solver searches.
The model consists of places, transitions, and tokens.

- data types for places, transitions, and tokens
- validation of the input to the solver
- applying one transition
- the types of the witnesses that the solver returns (reachability, closure, deadlock, acyclicity)

The closure is the set of all reachable states.

## Tools

The generator, which produces Gleam types and codecs from declarations of types and operations, and the solver, which searches for reachable states, are in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Their license is AGPL-3.0-only.

## Initializing generated code

To identify a generation, the package provides the following two functions:

```gleam
semantic_signatures.generation_requirement(checked: CheckedGeneration) -> GenerationRequirement
semantic_signatures.require_generation(required: GenerationRequirement, checked: CheckedGeneration) -> Result(CheckedGeneration, GenerationMismatch)
```

`generation_requirement` extracts a typed generation requirement of nine fields from an accepted generation value.
`require_generation` compares a generation requirement with a checked generation value and returns every difference.

A generated module provides an initialization function of the following form:

```gleam
initialize(checked: CheckedGeneration) -> Result(Context, GenerationMismatch)
```

`Context` is the type of the context that the initialization function returns.
On success, the context holds the generation value that the caller accepted, and it serves as the input to the generated values, codecs, and operations.

## Installation

```bash
gleam add necoherence
```

## Development checks

The following commands run the format check, the build, and the tests:

```bash
gleam format --check
gleam build --warnings-as-errors
gleam test
```

## License

[MIT](LICENSE)
