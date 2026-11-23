// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";

type Json = any;
type Step = string | number;

const readExample = (name: string) => JSON.parse(readFileSync(new URL(`../../../../verification/declaration/signature_admission/examples/${name}.request.json`, import.meta.url), "utf8")) as { readonly exchange: string };
const acceptedComposition = readExample("accepted-composition");

function setPath(root: Json, path: readonly Step[], value: Json): void {
  let current = root;
  for (const step of path.slice(0, -1)) current = current[step];
  current[path[path.length - 1]!] = value;
}

function emptyTypesPath(root: Json, path: Step[] = []): Step[] | null {
  if (Array.isArray(root)) {
    for (const [index, item] of root.entries()) { const found = emptyTypesPath(item, [...path, index]); if (found !== null) return found; }
  } else if (root !== null && typeof root === "object") {
    if (Object.hasOwn(root, "empty_types")) return [...path, "empty_types"];
    for (const [key, item] of Object.entries(root)) { const found = emptyTypesPath(item, [...path, key]); if (found !== null) return found; }
  }
  return null;
}

function admitChanged(change: (composition: Json) => void, example: { readonly exchange: string } = acceptedComposition) {
  const exchange = JSON.parse(example.exchange) as Json;
  change(exchange.composition);
  const basis = S.signatureBasis(exchange.signatures, exchange.entrypoints, exchange.composition);
  exchange.basis = basis;
  return S.admitSignatureGeneration(S.expectedSignatureBasis(exchange), JSON.stringify(exchange));
}

const bogus = { tag: "Bogus" };
const wireFailureTags = new Set(["Syntax", "UnknownTag", "UnknownField"]);

describe("composition problem and derivation wire mutations produce typed failures", () => {
  const cases: readonly (readonly [string, readonly Step[], Json, "Wire" | "CompositionInput", readonly string[]])[] = [
    ["empty input port type id", ["problem", "signatures", 1, "inputs", 0, "contract", "type_id"], "", "CompositionInput", ["UnresolvedType"]],
    ["empty output port type id", ["problem", "signatures", 0, "outcomes", 0, "value_ports", 0, "contract", "type_id"], "", "CompositionInput", ["InvalidSignature"]],
    ["cause origin source number", ["problem", "signatures", 0, "outcomes", 0, "cause", "fields", "origin", "source"], 5, "Wire", ["Syntax"]],
    ["signature effect tag unknown", ["problem", "signatures", 1, "effect"], bogus, "Wire", ["UnknownTag"]],
    ["allowed effect tag unknown", ["problem", "allowed_effects"], [bogus], "Wire", ["UnknownTag"]],
    ["signature reference number", ["problem", "signatures", 1, "reference"], 1, "Wire", ["Syntax"]],
    ["outcome cause tag unknown", ["problem", "signatures", 1, "outcomes", 0, "cause"], bogus, "Wire", ["UnknownTag"]],
    ["initial input contract number", ["problem", "initial_inputs"], [{ id: "a", contract: 5, source: bogus, resource: null }], "Wire", ["Syntax"]],
  ];
  it.each(cases)("%s", (_name, path, value, kind, tags) => {
    const admitted = admitChanged(composition => setPath(composition, path, value));
    expect(admitted.tag).toBe("Failed");
    if (admitted.tag === "Failed") {
      expect(admitted.failure.tag).toBe(kind);
      expect(tags).toContain((admitted.failure as { value: { tag: string } }).value.tag);
    }
  });

  const inclusion = ["derivation", "plan", "root", "node", "fields", "arms", 0, 1, "node", "value", "value", 0, 1, "fields", "compatibility", "value"] as const;
  it.each([
    ["inclusion certificate", inclusion],
    ["inclusion pair row", [...inclusion, "pairs", 0]],
  ])("rejects an unknown key on %s as a typed wire failure", (_name, path) => {
    const admitted = admitChanged(composition => {
      const target = path.reduce((node: Json, step) => node[step], composition);
      target.extra = 1;
    });
    expect(admitted).toEqual({
      tag: "Failed",
      failure: { tag: "Wire", value: { tag: "UnknownField", path: expect.stringMatching(/\.extra$/), value: "extra" } },
    });
  });

  it("rejects malformed fields on composition records with typed wire failures", () => {
    const admitted = admitChanged(composition => {
      composition.problem.signatures[1].form = bogus;
    });
    expect(admitted.tag).toBe("Failed");
    if (admitted.tag === "Failed" && admitted.failure.tag === "Wire") {
      expect(wireFailureTags.has(admitted.failure.value.tag)).toBe(true);
    }
  });
});

describe("derivation decode follows tagged sums", () => {
  it("reports an unknown plan node tag", () => {
    expect(admitChanged(composition => setPath(composition, ["derivation", "plan", "root", "node", "tag"], "NoSuchTag"))).toMatchObject({ tag: "Failed", failure: { tag: "Wire", value: { tag: "UnknownTag" } } });
  });
  it.each([[{ tag: "Bogus" }], [{ tag: "Bogus", extra: 1 }]])("reports an unknown selection tag %j", selection => {
    expect(admitChanged(composition => setPath(composition, ["derivation", "selection"], selection))).toMatchObject({ tag: "Failed", failure: { tag: "Wire", value: { tag: "UnknownTag" } } });
  });
  it.each([[""], ["undeclared"]])("admits an inclusion certificate with the empty type %j, because the runtime admission does not verify the derivation", name => {
    const path = emptyTypesPath(JSON.parse(acceptedComposition.exchange).composition.derivation)!;
    const admitted = admitChanged(composition => setPath(composition, ["derivation", ...path], [name]));
    expect(admitted.tag).toBe("Admitted");
  });
});

describe("exact decimal text follows the JSON number reader", () => {
  const texts = ["1e10000", "1e-10000", "1E+10000", "1e99999999999", "1e-99999999999", "1e4294967296", "1e4294967295", "-1e10000"];
  it.each(texts)("rejects the decimal text %s in an exact value", text => {
    expect(() => S.wireExactJson({ tag: "Decimal", text }, "$")).toThrow(expect.objectContaining({ failure: { tag: "Syntax", path: "$.text", value: "invalid exact decimal" } }));
  });
  it.each(["1e9999", "1e-9999", "1.5E+42", "-0.25"])("accepts the decimal text %s in an exact value", text => {
    expect(() => S.wireExactJson({ tag: "Decimal", text }, "$")).not.toThrow();
  });
});

describe("exchange text", () => {
  const exchangeWith = (member: string) => `{"x":${member},"schema":"ncoh-checked-generation@5"}`;
  const zeros = "0".repeat(5000);
  it.each([["1e10000", "1e10000"], ["1E+10000", "1E+10000"], ["1e100000", "1e100000"], ["1e4294967295", "1e4294967295"], ["1e-10000", "1e-10000"], ["1E-10000", "1E-10000"], ["1e-4294967296", "1e-4294967296"], ["twenty digits", "1e99999999999999999999"], ["negative twenty digits", "1e-99999999999999999999"], ["negative zeros then 10000", `1e-${zeros}10000`], ["zeros then 10000", `1e${zeros}10000`]])("rejects the exponent %s as a JSON syntax failure", (_name, member) => {
    expect(S.decodeGenerationInput(exchangeWith(member))).toEqual({ tag: "Failed", failure: { tag: "Json", value: { tag: "Syntax", path: "$", value: "exponent too large" } } });
  });
  it.each([["1e9999", "1e9999"], ["1e-9999", "1e-9999"], ["1e-42", "1e-42"], ["negative zeros then 5", `1e-${zeros}5`], ["positive zeros then 5", `1e+${zeros}5`], ["negative zeros then 9999", `1e-${zeros}9999`]])("parses the exponent %s below the limit and reports the unknown member", (_name, member) => {
    expect(S.decodeGenerationInput(exchangeWith(member))).toMatchObject({ tag: "Failed", failure: { tag: "Wire", value: { tag: "UnknownField" } } });
  });
  it.each([[20000], [200000]])("reports a nested array of depth %i as a typed wire failure", depth => {
    expect(S.decodeGenerationInput("[".repeat(depth) + "]".repeat(depth))).toMatchObject({ tag: "Failed", failure: { tag: "Wire", value: { tag: "Syntax" } } });
  });
  it.each([[20000], [200000]])("reports a nested object of depth %i as a typed wire failure", depth => {
    expect(S.decodeGenerationInput('{"a":'.repeat(depth) + "1" + "}".repeat(depth))).toMatchObject({ tag: "Failed", failure: { tag: "Wire", value: { tag: "UnknownField" } } });
  });
});
