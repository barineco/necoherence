// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import assert from "node:assert/strict";
import { semanticSignatures as S } from "necoherence";
import { renderSignatureGeneration } from "../dist/index.js";

const digest = "a".repeat(64), reference = { identity: "consumer", revision: "4", content_digest: digest };
const library = {
  schema: "ncoh-type-signatures@1", identity: "consumer", revision: "4",
  profile: { reference, source_refs: [], integer_domains: [{ name: "integer", reference, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }] }], default_integer_domain: "integer", numbers: { decimals: true }, grapheme_rules: null, format_bindings: [], bytes_policy: null, wrappers: [], tag: null },
  sources: [], provenance: [], groups: [], annotations: [],
  nodes: [{ id: "text", shape: { tag: "String", value: { format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null } } }],
  definitions: [{ id: "text", wire_identity: "Text", shape: { tag: "Value", value: "text" } }],
};
const entrypoints = [{ identity: "Text", definition: "text" }];
const basis = S.signatureBasis(library, entrypoints);
const exchange = { schema: "ncoh-checked-generation@4", basis, signatures: library, composition: null, entrypoints };
const admitted = S.admitSignatureGeneration(basis, JSON.stringify(exchange));
assert.equal(admitted.tag, "Admitted");
const value = { tag: "String", value: "consumer" };
assert.deepEqual(admitted.checked.codec("text").decode(admitted.checked.codec("text").encode(value)), value);
const rendered = renderSignatureGeneration(admitted.checked);
assert.match(rendered, /T_74657874Codec/);
assert.doesNotMatch(rendered, /from ["']necoherence-tools["']/);
process.stdout.write(JSON.stringify({ admittedInputs: 1, codecRoundtrips: 1, generatedConsumers: 1 }) + "\n");
