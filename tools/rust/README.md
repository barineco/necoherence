# Necoherence tools for Rust

Search, derivation, and Rust code generation for Necoherence declarations.
This crate is licensed under AGPL-3.0-only; the `necoherence` runtime is MIT.

## Installation

```toml
[dependencies]
necoherence-tools = "0.2.2"
```

## Public modules

The crate has three public modules.

- `composition_search`: searches for compositions that reach a goal and assesses their terminal states
- `typed_mapping_solver`: explores markings and checks reachability, deadlock, and well-foundedness
- `renderer`: renders libraries, generation exchanges, and checked compositions as Rust source

Generated code uses the separate runtime crate. See the
[tools guide](https://github.com/barineco/necoherence/blob/publish/tools/README.md)
for generation inputs, semantic profiles, and composition contracts.

## Development

In a repository checkout, run the tests from this crate directory:

```sh
cargo test --locked
```

The published crate contains the library sources, the README, and the license.
The test harnesses that read fixtures from other directories stay in the repository.
Repository builds resolve the runtime through a path dependency.
The packaged crate depends on the runtime release 0.2.2 from crates.io, so the runtime is published first.
