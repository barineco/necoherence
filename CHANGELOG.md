# Changelog

## 0.1.0

Necoherence updates state safely. Each resource has a revision, and each update names the observed revision that it is based on. The definitions are verified in Lean 4, and every operation returns either a result or an explicit failure.

The library provides these features:

- `Core`: state updates and failure classification.
- `Call`: declared calls, issued immediately or deferred, and the observation of their results.
- `Iteration`: bounded iteration as fold, recurse, and closure.
- `Store`: a value for each resource.
- `Record`: a record of each call with its declaration, input, result, and basis.
- `Reconcile`: comparison of a recorded call history with the current state.
- `Request progression`: submission, start order, cancellation, and completion of requests.
- `Dynamic admission`: admission of requests based on observed capacity.
- `Step transition`: the state transition for one input, with limits on reprocessing rounds and outputs.
- `File effect`: file operations and their observation.
- `Network effect`: HTTP attempts, observations from the executing host, and retry authorizations.

The implementations are Lean, Python, Rust, TypeScript, Java, and Gleam, under the MIT License.

The tools are released under AGPL-3.0-only:

- A generator that derives each language's types and codecs from declarations of types and operations.
- A solver for typed transition models that returns witnesses for reachability, closure, deadlock, and acyclicity.
- The verifier `residual-coherence`, which reports the reachable points that are missing from the declarations in analysis data.

Code produced by the generator and witnesses returned by the solver are available under the MIT License.
