# Necoherence for TypeScript

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This package is the TypeScript implementation of Necoherence.
Revisions and other natural numbers are represented as `bigint`.
It is provided as ES modules and is verified on Node.js 22 (the version used in CI).

## Accepting a semantic profile

The caller passes a versioned semantic profile when decoding declarations and when accepting a generated library.
The accepted profile defines the wire format used by validation, encoding and decoding, and execution.

The bundled preset is a profile for signatures.
The caller checks the trusted bytes, the expected reference, and the sources before accepting the library with `checkLibrary`.

```typescript
import { Buffer } from "node:buffer";
import { semanticSignatures as S, semanticValues as V } from "necoherence";

function decide(
  expected: V.ProfileRef, sources: readonly V.SourceIdentity[],
  trusted: Uint8Array, input: Uint8Array, library: S.TypeSignatureLibrary,
  typeId: string, value: V.ExactJson,
): V.ExactJson {
  V.requireEvidence(Buffer.from(trusted).equals(Buffer.from(input)), "profile bytes");
  const text = new TextDecoder("utf-8", { fatal: true }).decode(input);
  const profile = JSON.parse(text) as S.ValueSemanticProfile;
  V.requireEvidence(V.same(profile.reference, expected), "profile reference");
  V.requireEvidence(V.same(profile.source_refs, sources), "profile sources");
  const checked = S.checkLibrary({ ...library, profile });
  const reference = checked.refs.get(typeId);
  V.requireEvidence(reference, "type identity");
  return checked.context.validate(reference, value);
}
```

Failures are returned as the following types, one for each cause:

- `SemanticEvidenceError`: the bytes, reference, sources, or type differ from what was expected
- `DeclarationPredicateFailure`: the library violates a declaration condition
- `SemanticValueError`: validation rejected the value

## Other features

Besides the features listed in the [project overview](https://github.com/barineco/necoherence/blob/publish/README.md), the package provides the following:

- Declaration checking: detects errors in declarations of types and operations, such as duplicate identifiers and references to undeclared types or definitions
- Runtime for generated code: the shared value validation and codec routines that generated TypeScript code calls at run time
- HTTP adapter: executes the requests of the network effect with `fetch` and returns the results as observations

## Tools

The generator, which produces TypeScript types and codecs from declarations of types and operations, is in [tools/](https://github.com/barineco/necoherence/tree/publish/tools).
Its license is AGPL-3.0-only.

## Type checking and testing

The following commands run the type checks and the tests:

```bash
npm ci
npm run typecheck
npm test
```

## License

[MIT](LICENSE)
