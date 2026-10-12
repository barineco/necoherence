# Necoherence tools

[Project overview](../README.md) | [日本語](README-ja.md)

This directory holds the generator and the solver of Necoherence, implemented per language.
The generator produces code from declarations, and the solver searches transitions and returns witnesses.
Generated code is used together with the MIT-licensed implementation of its language.
That implementation also checks the reachability, closure, and acyclicity witnesses that the solver returns.
The MIT-licensed implementations are in these directories:

- [lean/](../lean/)
- [python/](../python/)
- [rust/](../rust/)
- [typescript/](../typescript/)
- [java/](../java/)
- [gleam/](../gleam/)

## Tools

- Generator: derives each language's types and codecs from declarations of types and operations
- Solver: searches a typed transition model made of places, transitions, and tokens, and returns a witness for reachability, closure (the set of all reachable states), deadlock, or acyclicity

Lean, Rust, and Gleam have both tools:

| Language | Generator | Solver |
| --- | --- | --- |
| Lean | yes | yes |
| Rust | yes | yes |
| Gleam | yes | yes |
| Python | yes | no |
| TypeScript | yes | no |
| Java | yes | no |

### Generator

Input: one JSON document in the `ncoh-checked-generation@4` format (called the input document below), which this JSON Schema defines:

- [ncoh-checked-generation-v4.schema.json](../comparison/declaration/ncoh-checked-generation-v4.schema.json)

The document has five fields:

- `schema`: the string `ncoh-checked-generation@4`
- `basis`: the generation premise, the information that pins down what is generated, including the declaration set's identity and revision and the digests of its graph, provenance, metadata, composition problem, and entrypoints
- `signatures`: a declaration set in the `ncoh-type-signatures@1` format. Its main content is of three kinds:
  - `nodes`: the declared types
  - `definitions`: values, symbols, messages, and operations. An operation declares its inputs and outcomes
  - `annotations`: metadata attached to the declaration set itself, a group, a definition, a type, or an outcome
- `composition`: `null`, or a composition problem with its derivation. The generator checks the derivation before it uses it
- `entrypoints`: the definitions to expose, each with an identity and a definition id

The caller passes a second input: the expected generation premise, in the form of the `basis` field, obtained independently of the input document.
The generator accepts the document only when its `basis` equals the expected one and matches the digests of its own contents.

The MIT-licensed implementations provide the function that computes the generation premise:

- Python: `signature_basis`
- TypeScript: `signatureBasis`
- Rust: `signature_basis` in `necoherence::signature_admission`
- Java: `TypeSignatures.basis`
- Gleam: `generation_basis`

Output: the source text of one file in the target language.

- Types and codecs for the declared values
- Types for each operation's arguments and outcomes
- The declared annotations
- When `composition` is given, code that runs the composition

The first line of the output is the comment line `SPDX-License-Identifier: MIT`, written in the comment syntax of the target language.
The generated code depends only on the MIT-licensed implementation of its language.

Failure: the generator returns an error for an invalid input document, for a mismatch with the expected generation premise, and for a rejected declaration or derivation.
Each language reports the error in its own form, as the Languages section lists.

### Solver

The solver has two parts, and both return an explicit result for every input.

Solver for the typed transition model:

- Input: a `SolverInput` of the typed transition model, with these parts:
  - places, transitions, and input bindings
  - a goal, a declaration graph, and the initial marking (the arrangement of tokens over the places)
  - a bound, with `max_bindings` and `max_search_steps`
- Model: the MIT-licensed implementations define it:
  - Lean: `Necoherence.TypedMapping`
  - Rust: `necoherence::typed_mapping`
  - Gleam: `necoherence/typed_mapping`
- Operations: reachability, deadlock, and well-foundedness

The results below use Rust's names.
Lean and Gleam have the same cases under their own names.

A closure is the set of all markings that are reachable.

| Operation | Result | Meaning |
| --- | --- | --- |
| Reachability | `Reachable` | The goal is reached. The witness is the transition path and the final marking |
| Reachability | `Unreachable` | The search explored the whole closure. The witness is that closure |
| Deadlock | `Deadlocked` | The goal is unmet and no transition is enabled. The witness is the marking |
| Deadlock | `NotDeadlocked` | The result carries the enabled transitions |
| Well-foundedness | `WellFounded` | The explored closure is acyclic. The witness is that closure |
| Well-foundedness | `NotWellFounded` | A marking repeats. The witness is the cycle |
| Each operation | `Invalid` | The declaration is invalid. The result carries the reason |
| Each operation | `Unknown` | The search stopped at the binding bound or at the search-step bound |

Rust and Gleam report a violated contract of the host program separately, as `SolverFailure`.
The Lean functions return only the results above.

Composition search:

- Input: a `PreparedCompositionInput`, built from a composition problem (the `composition.problem` of the input document)
  - A composition is a plan that combines declared functions to build a goal value from the initial inputs
  - The problem declares function signatures, initial inputs, and a goal
- Result: one of four cases:
  - `Solved`: a checked derivation
  - `Unreachable`: a closure
  - `Unknown`: the unresolved conditions
  - `Ambiguous`: the candidate plans
- Use of the result: a `Solved` derivation goes into `composition.derivation` of the input document, where the generators and the MIT-licensed implementations check it

## Languages

Each tool is used through function calls, and each section below lists the functions.
Lean also provides a command for the generator.

### Lean

- Directory: [lean/](lean/)
- Package: `necoherence-tools`
- Dependency: the MIT-licensed package `necoherence` in [../lean/](../lean/)

Generator command, run in `tools/lean`:

```bash
lake exe semantic_generation <input.json> <trusted-basis.json> <output.lean>
```

The second file holds the expected generation premise, in the same form as `basis` in the input document.
The command writes the Lean source to the third path and prints `generated signature nodes=N`.
An invalid input ends the command with an error.

Functions to call:

- Generator: `NecoherenceTools.SignatureComposition.generate`, which returns `Except String String`
- Solver: `NecoherenceTools.checkReachability`
- Solver: `NecoherenceTools.checkDeadlock`
- Solver: `NecoherenceTools.checkWellFoundedness`
- Composition search: `NecoherenceTools.CompositionSearch.derive`

### Rust

- Directory: [rust/](rust/)
- Crate: `necoherence-tools` (`publish = false`)
- Dependency: the MIT-licensed crate in [../rust/](../rust/), by path
- Requires: Rust 1.88 or later

```rust
// generator
necoherence_tools::renderer::render_signature_exchange(
    expected: &SignatureGenerationBasis, text: &str) -> Result<String, RenderFailure>
necoherence_tools::renderer::render(checked: &CheckedGeneration) -> Result<String, RenderFailure>

// solver
necoherence_tools::typed_mapping_solver::check_reachability(input: &SolverInput) -> Result<ReachabilityResult, SolverFailure>
necoherence_tools::typed_mapping_solver::check_deadlock(input: &SolverInput) -> Result<DeadlockResult, SolverFailure>
necoherence_tools::typed_mapping_solver::check_well_foundedness(input: &SolverInput) -> Result<WellFoundednessResult, SolverFailure>
necoherence_tools::composition_search::derive(prepared: &PreparedCompositionInput) -> Result<CompositionDecision, CompositionEngineFailure>
```

The function `render` takes an input document that has already been checked.

### Gleam

- Directory: [gleam/](gleam/)
- Package: `necoherence_tools`
- Dependency: the MIT-licensed package in [../gleam/](../gleam/), by path
- Target: Erlang

```gleam
// generator
necoherence/semantic_signatures.admit_generation(expected_json: String, input_json: String) -> Result(CheckedGeneration, Failure)
necoherence/semantic_signatures.generation_requirement(checked: CheckedGeneration) -> GenerationRequirement
necoherence/semantic_signatures.require_generation(required: GenerationRequirement, checked: CheckedGeneration) -> Result(CheckedGeneration, GenerationMismatch)
necoherence_tools/renderer.render_signatures(checked: CheckedGeneration) -> Result(String, RenderFailure)

// solver
necoherence_tools/typed_mapping_solver.check_reachability(input: SolverInput) -> Result(ReachabilityResult, SolverFailure)
necoherence_tools/typed_mapping_solver.check_deadlock(input: SolverInput) -> Result(DeadlockResult, SolverFailure)
necoherence_tools/typed_mapping_solver.check_well_foundedness(input: SolverInput) -> Result(WellFoundednessResult, SolverFailure)
necoherence_tools/composition_search.derive_composition(prepared: PreparedCompositionInput) -> Result(CompositionDecision, CompositionEngineFailure)
```

The admission function belongs to the MIT-licensed package, and its result is the input of the generator. The generated initialization function compares the module's typed generation requirement with the caller's checked generation. A successful context keeps that checked value for generated values, codecs, and operations.

The Gleam generator derives public types, constructors, values, and labels from declared type identities, signature wire identities, field wire names, port IDs, and outcome IDs. ASCII separators divide words, non-ASCII scalars use a stable scalar escape, and a role prefix makes leading digits and Gleam keywords valid. A target-language name collision returns `IdentifierCollision` with both declaration origins.

### Python

- Directory: [python/](python/)
- Package: `necoherence-tools`
- Requires: Python 3.12 or later, and the MIT-licensed package `necoherence`
- Provides: the generator

```python
necoherence_tools.render_expected(expected_basis: ExpectedSignatureBasis, exchange: str) -> str
necoherence_tools.render_checked(checked: CheckedSignatureGeneration) -> str
```

- `ExpectedSignatureBasis` comes from `necoherence.type_signatures`
- `render_checked` takes a generation that `admit_signature_generation` has already admitted
- A rejected input raises `GenerationFailure`

### TypeScript

- Directory: [typescript/](typescript/)
- Package: `necoherence-tools` (private, ES modules)
- Dependency: the MIT-licensed package in [../typescript/](../typescript/)
- Provides: the generator

```ts
renderSignatureGeneration(checked: CheckedSignatureGeneration, runtimeModule = "necoherence"): string
```

- The `checked` value comes from the admission function of the package `necoherence`
- Admission function: `semanticSignatures.admitSignatureGeneration(basis, exchangeJson)`
- A rejected input makes the admission function return `{ tag: "Failed", failure }`

### Java

- Directory: [java/](java/)
- Provides: the generator
- Build: `javac` builds the sources together with the MIT-licensed sources in [../java/](../java/)
- Requires: Java 21

```java
necoherence.tools.renderer.Renderer.render(
    SemanticGeneration.GenerationBasis basis, String exchange, Renderer.JavaTarget target) -> Renderer.RenderResult
```

- `JavaTarget`: the Java package name and the class name of the output
- `RenderResult`: one of two cases
  - `Rendered`: carries the source
  - `InvalidGeneration`: carries the path and the reason
- `Renderer.renderChecked` takes a generation that `TypeSignatures.admitGeneration` of the MIT-licensed sources has already admitted

## Build and test

The commands are the ones that the `tools-*` jobs of the CI workflow run:

- [ci.yml](../.github/workflows/ci.yml)

Run each set of commands in the directory given for its language.

### Lean

Use the toolchain specified by [lean-toolchain](lean/lean-toolchain), and run the following in `tools/lean`:

```bash
lake build NecoherenceTools NecoherenceToolsTest
```

### Gleam

Use Gleam 1.17 or later, and run the following in `tools/gleam`:

```bash
gleam format --check
gleam build --warnings-as-errors
gleam test
```

### Rust

Run the following in `tools/rust`:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

### Python

Use Python 3.12 or later.
First, run the following in the repository root:

```bash
python -m pip install -e python
python -m pip install -e "tools/python[dev]"
```

Then run the following in `tools/python`:

```bash
python -m pytest -q
python -m mypy src tests
```

### TypeScript

Use Node.js 22.
First, run the following in `typescript`:

```bash
npm ci
npm run build
```

Then run the following in `tools/typescript`:

```bash
npm ci
npm run build
npm run typecheck
npm test
```

### Java

The Java tools are built together with the MIT-licensed sources, and the tests that have a `main` method are run.
`SemanticSignatureCompositionTest` generates its scenarios with `comparison/declaration/signature_generator`, which uses the Rust tools.
For this reason, prepare Java 21 and a Rust toolchain, and then run the following in the repository root:

```bash
mkdir -p java/lib tools/java/build/classes tools/java/build/test-classes
curl --fail --location --silent --show-error \
  --output java/lib/junit-platform-console-standalone-1.10.2.jar \
  https://repo1.maven.org/maven2/org/junit/platform/junit-platform-console-standalone/1.10.2/junit-platform-console-standalone-1.10.2.jar
printf '%s  %s\n' \
  a1de557821293ce903c213c694165fff532cf92081bac4238b9e05b35f04f43f \
  java/lib/junit-platform-console-standalone-1.10.2.jar | shasum -a 256 -c -
find java/src/main/java tools/java/src/main/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 -d tools/java/build/classes
find java/src/test/java/necoherence/semantic tools/java/src/test/java -name '*.java' -print0 \
  | xargs -0 javac -J-Duser.language=en --release 21 \
      -cp tools/java/build/classes:java/lib/junit-platform-console-standalone-1.10.2.jar \
      -d tools/java/build/test-classes
for test in SemanticInvariantAdapterTest SemanticJavaSizeTest SemanticJavaTargetTest SemanticSignatureCompositionTest SemanticSignatureTest GeneratedJavaSemanticTest; do
  java -Duser.language=en -cp tools/java/build/classes:tools/java/build/test-classes:java/lib/junit-platform-console-standalone-1.10.2.jar \
    "necoherence.tools.renderer.$test"
done
for test in ProfileLibraryPredicateTest InclusionAndSamplesTest DeclarationWireTest; do
  java -Duser.language=en -cp tools/java/build/classes:tools/java/build/test-classes:java/lib/junit-platform-console-standalone-1.10.2.jar \
    "necoherence.semantic.$test"
done
```

## License

The tools in this directory are licensed under [AGPL-3.0-only](LICENSE).
The dependency runs in one direction, from the tools to the MIT-licensed implementations.

The code that the generator produces and the witnesses that the solver returns are available under the MIT License.
Generated code states this in its first line, and the JSON Schema that defines the input document is also under the MIT License.

Each file's license is declared by the SPDX line at its top or by [REUSE.toml](../REUSE.toml).
