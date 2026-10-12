// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";

const digest = "a".repeat(64);
const profileReference: V.ProfileRef = { identity: "general-values", revision: "4", content_digest: digest };
const profile: S.ValueSemanticProfile & V.VersionedSemanticProfile = {
  reference: profileReference,
  source_refs: [],
  integer_domains: [{ name: "integer", reference: profileReference, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }, { tag: "DecimalString" }] }],
  default_integer_domain: "integer",
  numbers: { decimals: true },
  grapheme_rules: null,
  format_bindings: [{ name: "identifier", reference: profileReference, rule: { tag: "Identifier", fields: { first_alphabet: "abcdefghijklmnopqrstuvwxyz", rest_alphabet: "abcdefghijklmnopqrstuvwxyz0123456789", exact_length: null, min_length: "1", max_length: null, forbidden: [] } } }],
  bytes_policy: { reference: profileReference, padding_optional: true, alphabet: { tag: "Standard" }, strict_pad_bits: true, wrapper: "bytes" },
  wrappers: [{ name: "text", key: "wrapped", payload: { tag: "Text", value: "identifier" } }, { name: "bytes", key: "binary", payload: { tag: "Bytes" } }],
  tag: { key: "kind", format: "identifier", sealed: [{ tag: "sealed", fields: [{ key: "name", required: true, leaf: { tag: "String", value: { format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null } } }], extras: { tag: "Reject" } }] },
};
const library: S.TypeSignatureLibrary = {
  schema: "ncoh-type-signatures@1", identity: "representative", revision: "4", profile,
  sources: [], provenance: [], groups: [], annotations: [],
  nodes: [
    { id: "never", shape: { tag: "Never" } },
    { id: "integer", shape: { tag: "Integer", value: { domain: null, minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } } },
    { id: "sealed", shape: { tag: "Sealed", fields: { tag: "sealed", refinements: [] } } },
    { id: "union", shape: { tag: "TaggedUnion", value: { branches: [{ target: "sealed", wire_tag: "sealed", selector: { tag: "InternalTag" } }] } } },
  ],
  definitions: [{ id: "integer", wire_identity: "integer", shape: { tag: "Value", value: "integer" } }, { id: "never", wire_identity: "never", shape: { tag: "Value", value: "never" } }],
};

it("checks the representative profile and library through their sole validators", () => {
  expect(S.checkProfile(profile).reference).toEqual(profileReference);
  const checked = S.checkLibrary(library);
  expect(checked.context.validate(checked.refs.get("integer")!, { tag: "String", value: "42" })).toEqual({ tag: "String", value: "42" });
  expect(() => checked.context.validate(checked.refs.get("never")!, { tag: "Null" })).toThrow(/InvalidDataModel/);
  expect(() => S.checkProfile({ ...profile, default_integer_domain: "missing" })).toThrow(/PR05/);
});

it("admits only the fourth checked-generation wire and preserves a canonical roundtrip", () => {
  const entrypoints = [{ identity: "integer", definition: "integer" }], basis = S.signatureBasis(library, entrypoints);
  const input: S.SignatureGenerationInput = { schema: "ncoh-checked-generation@4", basis, signatures: library, composition: null, entrypoints };
  const admitted = S.admitSignatureGeneration(basis, JSON.stringify(input));
  expect(admitted.tag).toBe("Admitted");
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const value: V.ExactJson = { tag: "Integer", value: "900719925474099312345" };
  expect(admitted.checked.codec("integer").decode(admitted.checked.codec("integer").encode(value))).toEqual(value);
  const obsolete = S.admitSignatureGeneration(basis, JSON.stringify({ ...input, schema: "ncoh-checked-generation@3" }));
  expect(obsolete).toMatchObject({ tag: "Failed", failure: { tag: "UnsupportedSchema" } });
});

it("uses the general wrapper, member and branch runtime operations", () => {
  expect(V.wrapDecode(profile, "text", V.wrapEncode(profile, "text", "ab01"))).toBe("ab01");
  const tagged = V.withMember("kind", "sealed", { tag: "Object", members: [{ key: "name", value: { tag: "String", value: "x" } }] });
  const checked = S.checkLibrary(library), union = checked.refs.get("union")!;
  expect(V.selectBranch(checked.context.graph, union, tagged)?.wire_tag).toBe("sealed");
  expect(checked.context.validate(union, tagged)).toEqual(tagged);
});
