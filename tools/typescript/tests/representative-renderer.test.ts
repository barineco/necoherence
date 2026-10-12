// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { expect, it } from "vitest";
import { semanticSignatures as S } from "necoherence";
import { renderSignatureSurface } from "../src/signature_renderer.js";

const digest = "a".repeat(64), reference = { identity: "renderer", revision: "4", content_digest: digest };
const stringSpec = (wrapper: string | null = null) => ({ format: null, lengths: [], wrapper, const_value: null, enum_values: null, examples: [], default_value: null } as const);
const integerSpec = { domain: "integer", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null } as const;
const profile: S.ValueSemanticProfile = {
  reference, source_refs: [], integer_domains: [{ name: "integer", reference, range: { tag: "Unbounded" }, forms: [{ tag: "Number" }] }], default_integer_domain: "integer",
  numbers: { decimals: true }, grapheme_rules: null, format_bindings: [], bytes_policy: null,
  wrappers: [{ name: "text-wrapper", key: "wrapped", payload: { tag: "Text", value: null } }],
  tag: { key: "kind", format: null, sealed: [{ tag: "sealed", fields: [{ key: "label", required: true, leaf: { tag: "String", value: stringSpec() } }, { key: "count", required: false, leaf: { tag: "Integer", value: integerSpec } }], extras: { tag: "Reject" } }] },
};
const library: S.TypeSignatureLibrary = {
  schema: "ncoh-type-signatures@1", identity: "renderer", revision: "4", profile,
  sources: [], provenance: [], groups: [], annotations: [],
  nodes: [
    { id: "wrapped", shape: { tag: "String", value: stringSpec("text-wrapper") } },
    { id: "integer", shape: { tag: "Integer", value: integerSpec } },
    { id: "decimal", shape: { tag: "Decimal", value: { minimum: null, maximum: null } } },
    { id: "product", shape: { tag: "Product", value: { fields: [{ wire_name: "text", slot: { type_id: "wrapped", required: true, nullable: false } }, { wire_name: "decimal", slot: { type_id: "decimal", required: true, nullable: false } }], extras: { tag: "Reject" } } } },
    { id: "sealed", shape: { tag: "Sealed", fields: { tag: "sealed", refinements: [] } } },
    { id: "union", shape: { tag: "TaggedUnion", value: { branches: [{ target: "sealed", wire_tag: "sealed", selector: { tag: "InternalTag" } }] } } },
    { id: "never", shape: { tag: "Never" } },
  ],
  definitions: [{ id: "entry", wire_identity: "entry", shape: { tag: "Value", value: "product" } }],
};

it("compiles and executes carrier codecs for the representative shapes", () => {
  const checked = S.checkLibrary(library);
  const runtime = resolve("../../typescript/dist/index.js");
  const sourceText = renderSignatureSurface({ checked, basis: { schema: "ncoh-checked-generation@4" } }, runtime);
  expect(sourceText).toContain("export type Type_never_6 = never");
  expect(sourceText).toContain("export type Type_decimal_2 = V.DecimalValue");
  expect(sourceText).toContain("export interface Type_sealed_4");
  const directory = mkdtempSync(resolve(tmpdir(), "ncoh-representative-renderer-"));
  try {
    writeFileSync(resolve(directory, "generated.mts"), sourceText);
    writeFileSync(resolve(directory, "runner.mts"), `import * as G from "./generated.mjs";
import { semanticValues as V } from ${JSON.stringify(runtime)};
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
const wrapped = "hello";
if (G.Type_wrapped_0Codec.decode(G.Type_wrapped_0Codec.encode(wrapped)) !== wrapped) throw new Error("wrapper");
const decimal = new V.DecimalValue("1.25");
if (String(G.Type_decimal_2Codec.decode(G.Type_decimal_2Codec.encode(decimal))) !== "1.25") throw new Error("decimal");
const product = { text: wrapped, decimal };
const productDecoded = G.Type_product_3Codec.decode(G.Type_product_3Codec.encode(product));
if (productDecoded.text !== wrapped || String(productDecoded.decimal) !== "1.25") throw new Error("product");
const sealed = { label: "x", count: 2n };
const sealedDecoded = G.Type_sealed_4Codec.decode(G.Type_sealed_4Codec.encode(sealed));
if (sealedDecoded.label !== "x" || sealedDecoded.count !== 2n) throw new Error("sealed");
const union = { branch: "sealed" as const, value: sealed };
const unionDecoded = G.Type_union_5Codec.decode(G.Type_union_5Codec.encode(union));
if (unionDecoded.branch !== "sealed" || unionDecoded.value.label !== "x") throw new Error("union");
let rejected = false;
try { G.Type_never_6Codec.decode({ tag: "Null" }); } catch { rejected = true; }
if (!rejected || !same(G.Type_wrapped_0Codec.encode(wrapped), { tag: "Object", members: [{ key: "wrapped", value: { tag: "String", value: "hello" } }] })) throw new Error("wire");
`);
    execFileSync(process.execPath, [resolve("node_modules/typescript/bin/tsc"), resolve(directory, "generated.mts"), resolve(directory, "runner.mts"), "--outDir", resolve(directory, "compiled"), "--target", "ES2022", "--module", "NodeNext", "--strict", "--skipLibCheck"], { encoding: "utf8", stdio: "pipe" });
    execFileSync(process.execPath, [resolve(directory, "compiled/runner.mjs")], { encoding: "utf8", stdio: "pipe" });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
