# Necoherence for Lean 4

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This package is the Lean 4 implementation of Necoherence.
It writes the features listed in the [project overview](https://github.com/barineco/necoherence/blob/publish/README.md) as executable definitions, and the implementations in the other languages treat these definitions as their specification.
Building it requires the Lean toolchain v4.32.1.

The caller passes a `VersionedSemanticProfile` when checking declarations and when accepting a generated library.
Every wire key used by validation, projection, and execution comes from the wrapper, tag, and sealed-form declarations in this profile.
The profile and the library are checked before use.

## Declaration checking

Declaration checking includes the following:

- the conditions that declarations of types and operations satisfy
- theorems showing that, in a checked set of declarations, every referenced type is declared
- theorems showing that extending an operation keeps its original results
- the definitions that generated Lean code uses

## Typed transition model

`Necoherence.TypedMapping` defines the model that the solver searches.
The model consists of places, transitions, and tokens.

- data types for places, transitions, and tokens
- validation of the input to the solver
- applying one transition, and path replay, which applies a given sequence of transitions in order
- the types of the witnesses that the solver returns (reachability, closure, deadlock, acyclicity)
- theorems showing that the reason reported for an invalid input really holds, and that path replay agrees with the transition relation

The closure is the set of all reachable states.

## Residual coherence

This part includes a finite model of the residual extent and theorems that hold for every model, such as the extent being at least 0.
The residual extent is the total contribution to the measure from the derived points that are absent from the declarations.

## Network effect runner

`network_effect_runner` is an executable that reads one JSON request from standard input and writes the result as JSON ([request format](https://github.com/barineco/necoherence/blob/publish/lean/Necoherence/NetworkEffectRunner.lean)).
The outputs of the other implementations are compared with this output.

## Tools

The generator, which produces Lean code, and the solver are in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Their license is AGPL-3.0-only.
The verifier for residual coherence is in [residual-coherence](https://github.com/barineco/necoherence/tree/publish/residual-coherence).

## Build and run

The following commands build the package (including the theorem checks), check the residual coherence theorems numerically, and run `network_effect_runner`:

```bash
lake build
lake env lean Tests/ResidualCoherenceTheorems.lean
lake exe network_effect_runner < request.json
```

## License

[MIT](LICENSE)
