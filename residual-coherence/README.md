# residual-coherence

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

residual-coherence is a package that verifies residual coherence.
The residual here is the difference between the points that analysis data declares reachable and the points that can be derived from the analysis data as reachable.
The package validates the analysis data and reports this difference as the residual extent.
The residual extent is the sum of the measure contributions (`measure_contribution`) of the derived points that are absent from the declarations.

The analysis data is an `AnalysisInput`, whose fields are listed in [analysis-input.schema.json](schema/analysis-input.schema.json).
The analysis data contains the following three things:

- the points whose reachability is decided, each with its measure contribution
- the branches
- the points declared reachable

Each branch derives as reachable the points in its region whose value for the type that the branch requires (`required_type`) is one of the branch's listed values.

The package also converts normalized analysis structures (the `normalized-analysis` format, produced by other tools) into an `AnalysisInput`, and extracts analysis data from Python source text that you pass in.

## Install

It runs on Python 3.12 or later and uses only the standard library at run time.

Clone the repository, then install the package from its `residual-coherence` directory:

```sh
git clone https://github.com/barineco/necoherence
cd necoherence/residual-coherence
python -m pip install .
```

## Command line

Run `residual-coherence <command>` with one JSON value on standard input.
On success, it writes canonical JSON (with keys and set elements in a defined order) to standard output and exits with status 0.
On any failure, including malformed input, it writes a typed failure to standard error and exits with status 1.
A typed failure is a JSON object with a `kind`, a `path`, and optional detail text.
The `path` locates the problem.
It is a JSON path such as `$.schema_version`.
For a failure found in a source file, `python-source` reports the path of that file instead.

| Command | Purpose |
|---|---|
| `validate` | Validates an `AnalysisInput` and prints it in canonical form |
| `report` | Computes the declared extent, the derived extent, and the residual extent: the sums of the measure contributions of the declared points, the derived points, and the derived points that are not declared |
| `reachability` | Derives the reachable points: the points in a branch's region whose value for the type that the branch requires (`required_type`) is one of the branch's listed values |
| `verify` | Runs eight self-consistency checks on an `AnalysisInput`: it reruns the derivation, the report, and the canonical encoding on the input, and prints for each check the observed value next to the expected one |
| `normalized-analysis` | Validates a normalized analysis structure and prints the validated structure, the findings (a classification of each correspondence), the converted `AnalysisInput`, and its report |
| `typed-reachability` | Validates typed reachability data and prints the results of its verification checks, the digest of the converted `AnalysisInput`, and the diagnostic |
| `python-source` | Extracts analysis data from Python source text (experimental) |

### Normalized analysis

The command `normalized-analysis` reads a JSON object in the `normalized-analysis` format, regardless of which tool produced it.
The `schema_version` of the object is:

```json
{"schema_version": {"name": "normalized-analysis", "major": "1"}}
```

In addition to `schema_version`, the object has exactly these members, all required:

- `source_revision`: a non-empty string
- `language`: the language of the source, written as one of these lowercase JSON strings:
  - `python`
  - `gleam`
- ten groups of relation tables, each an array of rows:
  - `declarations`
  - `types`
  - `values`
  - `operation_inputs`
  - `branches`
  - `control_flow`
  - `place_accesses`
  - `external_effects`
  - `source_spans`
  - `stage_correspondences`

The command checks that every reference between the tables points to an existing identifier, then converts the structure.
The same input always produces the same result.

The fields of each row (for example `branch` and `digest`), and the classification of the findings, are defined in [normalized_analysis.py](https://github.com/barineco/necoherence/blob/publish/residual-coherence/src/residual_coherence/normalized_analysis.py).

### Python source analysis

The command `python-source` is experimental.
Its input is an object with a `revision` and a `sources` map from each path to its Python source text.
It parses each source into a syntax tree and detects these structures:

- `FlagCartesianProduct`: a function with two or more ordinary parameters annotated as `bool`, whose flags multiply the combinations it handles
- `ReceiverHiding`: a function whose first parameter has one of these names, so that part of its input is passed implicitly
  - `self`
  - `cls`
- `AmbientRead`: a function that reads a name assigned at module level, without receiving it as an argument

For `AmbientRead`, only a plain assignment of the form `name = value` defines a module-level name.
An annotated assignment such as `name: int = 1` is excluded from this check.

The result is an object with three members:

- `source_revision`: the revision and the digest of the sources
- `input`: an `AnalysisInput`
  - it holds the declared baseline point `p-baseline`
  - it holds one point for each detected structure
- `source_evidence`: the source locations that support the result

A detected point is not declared, so it enters the residual extent.
The supported scope is detecting the three structures above and reporting the typed failures below.

If a source contains one of the following, the command returns a typed failure instead of an analysis result:

- `DynamicImport`: a dynamic import call such as `__import__`
- `Reflection`: a call to a reflective built-in, for example one of these:
  - `getattr`, except a three-argument call whose default is a name or a constant
  - `setattr`
- `UndeclaredExternalOutput`: a call to one of these built-in functions
  - `print`
  - `open`
- `UnannotatedAny`: an `Any` annotation on a parameter or variable
- `UnclosedExpression`: a syntax error, an empty source set, or an unreadable file given to `extract_paths`

Example:

```sh
printf '%s\n' '{"revision":"example","sources":{"sample.py":"value: int = 1\n"}}' | residual-coherence python-source
```

### Typed reachability

The command `typed-reachability` reads a JSON object with two members.
The member `artifact` is typed reachability data: a closed set of types and constructors, branch regions, and the correspondence of each point across its surface, core, and native forms.
Its fields are listed in [typed-reachability-artifact.schema.json](schema/typed-reachability-artifact.schema.json).
The `source_revision` of the data has three non-empty string fields:

- `repository`
- `revision`
- `tree_digest`

The member `provenance` is an object with exactly two values, each a SHA-256 digest written as `sha256:` followed by 64 lowercase hexadecimal digits.
The key names are free, and the values are copied into the output.

A minimal input is in the source tree at `examples/typed-reachability-minimal.json`.
The installed package has it at `residual_coherence/examples/typed-reachability-minimal.json`.
After installing the package from the source tree, run this command in the `residual-coherence` directory; it exits with status 0 and prints the verification result:

```sh
residual-coherence typed-reachability < examples/typed-reachability-minimal.json
```

## JSON Schemas

The JSON Schemas in `schema/` describe the input and output of four commands:

- [analysis-input.schema.json](schema/analysis-input.schema.json): the `AnalysisInput`, which `validate` reads
- [residual-coherence-report.schema.json](schema/residual-coherence-report.schema.json): the output of `report`
- [analysis-verification.schema.json](schema/analysis-verification.schema.json): the output of `verify`
- [typed-reachability-artifact.schema.json](schema/typed-reachability-artifact.schema.json): the `artifact` member of the `typed-reachability` input
- [typed-reachability-verification.schema.json](schema/typed-reachability-verification.schema.json): the output of `typed-reachability`
- [reachability-diagnostic.schema.json](schema/reachability-diagnostic.schema.json): the `diagnostic` member of that output

## Python API

The main functions are:

- `validate_analysis_input`: validates an `AnalysisInput`
- `calculate_report`: computes the residual extent report
- `reduce_normalized_analysis_structure`: converts a normalized analysis structure into an `AnalysisInput`
- `reduce_typed_reachability`: converts typed reachability data into an `AnalysisInput`
- `extract_sources`: extracts analysis data from Python source text
- `extract_paths`: extracts analysis data from Python source files

Failures are represented by these values:

- `TypedFailure`: a failure while validating, encoding, reporting on, or running verification checks on an `AnalysisInput`
- `CanonicalConsumerFailure`: a failure while decoding a normalized analysis, validating its structure, checking its references, or presenting it
- `ReachabilityReductionFailure`: a failure while validating, converting, diagnosing, or running verification checks on typed reachability data
- `AnalysisFailure`: a failure while analyzing Python source

The method `as_dict()` converts each value to the dictionary that the command line prints as JSON.
The package's `__all__` lists the other public names.

## Development

Install the development dependencies, then test, type-check, and build:

```sh
python3 -m pip install ".[dev]"
python3 -m pytest -q
python3 -m mypy src tests
python3 -m build
```

## License

- Verifier source and tests: [AGPL-3.0-only](LICENSE)
- JSON Schemas for the data exchanged with the verifier: [MIT](schema/LICENSE)

The license conditions of the input passed to the verifier, and of the results it outputs, are decided by the author of the input.
