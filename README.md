# Necoherence

[日本語](README-ja.md)

Necoherence is a library for working with type signatures and the meaning of values.

## Capabilities

In Necoherence, you declare operations together with the types of their inputs and results, and then run the declared operations.
State is held per resource, as a pair of a value and a revision (a version number).
Every capability is implemented on top of definitions verified in Lean 4.

- `Core`: updating a resource on the basis of an observed revision, and classifying failures
- `Call`: running a declared operation and observing its result
- `Iteration`: iteration with an upper bound on rounds (fold, recurse, closure)
- `Store`: holding the value and revision of each resource
- `Record`: recording the operations that ran (declaration, input, result)
- `Reconcile`: comparing the operation records with the current state of the resources
- `Request progression`: tracking a request from start to finish
- `Dynamic admission`: deciding whether a request may start, based on the spare capacity
- `Step transition`: the state transition for each single input
- `File effect`: file operations and observation of their results
- `Network effect`: HTTP attempts, observation on the executing host, and retry authorization

Every operation returns either a result or an explicit failure, depending on its input.

## Tools

The generator and the solver are in [tools/](tools/), and the verifier is the Python package [residual-coherence](residual-coherence/).

- Generator: generates each language's types and codecs from declarations of types and operations
- Solver: searches a typed transition model for reachable states
- Verifier: checks the declarations of reachable points written in analysis data

## Implementations

Necoherence provides an implementation for each of the following six languages.

- [Lean](lean/)
- [Python](python/): for Python 3.12 or later
- [Rust](rust/)
- [TypeScript](typescript/)
- [Java](java/): for Java 21
- [Gleam](gleam/): for the Erlang target

The Lean implementation is the specification, written as executable definitions.
The implementations in the other five languages are verified by checking their results against those of the Lean definitions.
Every implementation is at version `0.2.1`, and each directory's README describes how to build and test it.

HTTP execution is optional. Rust enables it with the `http-adapter` feature. The other runtime implementations provide separate adapter packages:

- [Python HTTP adapter](python-http-adapter/)
- [TypeScript HTTP adapter](typescript-http-adapter/)
- [Java HTTP adapter](java-http-adapter/)
- [Gleam HTTP adapter](gleam-http-adapter/)

The core packages contain the network-effect ledger and accept observations through caller-supplied ports.

## Verification

The checks and their methods are as follows.

- Network effect: comparing results between the Lean executable and the other implementations ([comparison/network_effect](https://github.com/barineco/necoherence/tree/publish/comparison/network_effect))
- Solver for the typed transition model: comparison with an independently written reference implementation ([comparison/typed_mapping_solver](https://github.com/barineco/necoherence/tree/publish/comparison/typed_mapping_solver))
- Declarations and presets: comparing semantics across the six languages ([comparison/declaration](https://github.com/barineco/necoherence/tree/publish/comparison/declaration))
- Reproducible data: comparing files regenerated from their sources ([presets/tools](https://github.com/barineco/necoherence/tree/publish/presets/tools))
- Shared operations: comparing results and failure kinds across the six languages ([comparison/shared_operations](https://github.com/barineco/necoherence/tree/publish/comparison/shared_operations))
- Other features: each language's own tests
- HTTP adapters: tests that send real requests to a local test server

## Semantic profiles

The caller passes a versioned semantic profile when decoding declarations or accepting a generated library.
A semantic profile defines the following three things:

- format rules and the range of values
- Unicode grapheme data
- the wrappers, type tag, and sealed forms that classify JSON objects

Necoherence validates the profile it receives and uses the same profile for value validation, code generation, and execution.
The caller chooses which data model to use.

The repository includes the AT Protocol data model as a preset.
All six implementations read one shared profile from the repository, so each language package can be used independently of any particular data model.

- [presets/atproto-data-model/profile.json](presets/atproto-data-model/profile.json): the profile
- [presets/manifest.json](presets/manifest.json): identifier, version, sources, and SHA-256 digest

## License

Licenses by component are as follows:

- Language implementations: [MIT License](LICENSE)
- [Generator and solver](tools/): [AGPL-3.0-only](tools/LICENSE)
- [Verifier residual-coherence](residual-coherence/): AGPL-3.0-only
- JSON Schemas for the data exchanged with the verifier: [MIT License](residual-coherence/schema/LICENSE)

The code that the generator outputs and the witnesses that the solver returns are available under the MIT License.
Generated code also states this on its first line.

Each file's license can be checked in the SPDX declaration at the top of the file or in [REUSE.toml](REUSE.toml).
