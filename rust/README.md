# Necoherence for Rust

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This crate is the Rust implementation of Necoherence, for Rust 1.88 or later.

## Accepting a semantic profile

The caller passes a versioned semantic profile when decoding declarations and when accepting a generated library.
The accepted profile defines the wire format used by validation, encoding and decoding, and execution.

`decode_value_profile` takes a string.
The caller therefore compares the input with the trusted bytes before decoding the input as UTF-8.
The caller also checks the expected reference and sources.

```rust
use necoherence::exact_json::JsonValue;
use necoherence::semantic_exchange::decode_value_profile;
use necoherence::semantic_types::{ProfileRef, SourceIdentity, ValueDecision};
use necoherence::semantic_validation::accepts_value;
use necoherence::signature_admission::check_type_signatures;
use necoherence::type_signatures::{check_library, TypeSignatureLibrary};

fn decide(
    expected: &ProfileRef, sources: &[SourceIdentity], trusted: &[u8], input: &[u8],
    mut library: TypeSignatureLibrary, type_id: &str, value: &JsonValue,
) -> Result<ValueDecision, String> {
    if trusted != input { return Err("profile bytes differ".into()); }
    let text = std::str::from_utf8(input).map_err(|error| error.to_string())?;
    let profile = decode_value_profile(text).map_err(|error| error.to_string())?;
    if &profile.reference != expected || profile.source_refs != sources {
        return Err("profile basis differs".into());
    }
    library.profile = profile;
    check_library(&library).map_err(|error| format!("{error:?}"))?;
    let graph = check_type_signatures(&library).map_err(|error| error.to_string())?;
    let reference = &graph.nodes.iter()
        .find(|node| node.reference.definition_name.as_ref() == type_id)
        .ok_or("unknown type")?.reference;
    Ok(accepts_value(&graph, reference, value))
}
```

The public API returns failures and decisions as the following types:

- `GenerationFailure`: decoding the profile failed
- `LibraryCheckFailure`: checking the library failed
- `AdmissionFailure`: building the graph failed
- `ValueDecision`: the decision on a value
- `ValueFailure`: information about a rejected value

## Other features

Besides the features listed in the [project overview](https://github.com/barineco/necoherence/blob/publish/README.md), the package provides the following:

- Declaration checking: detects errors in declarations of types and operations, such as duplicate identifiers and references to undeclared types or definitions
- Runtime for generated code: the shared value validation and codec routines that generated Rust code calls at run time
- HTTP adapter: executes the requests of the network effect with `ureq` and returns the results as observations

## Typed transition model

The `typed_mapping` module defines the model that the solver searches.
The model consists of places, transitions, and tokens.

- data types for places, transitions, and tokens
- validation of the input to the solver
- applying one transition
- the types of the witnesses that the solver returns (reachability, closure, deadlock, acyclicity)

The closure is the set of all reachable states.

## Tools

The generator, which produces Rust types and codecs from declarations of types and operations, and the solver, which searches for reachable states, are in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Their license is AGPL-3.0-only.

## Installation

```bash
cargo add necoherence
```

## Development checks

The following commands run the format check, the lints, and the tests:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --all-targets
```

## License

[MIT](LICENSE)
