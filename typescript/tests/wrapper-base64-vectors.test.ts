// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import * as S from "../src/semantic_signatures.js";
import * as V from "../src/semantic_values.js";

type Outcome = {
  readonly accepted: boolean;
  readonly condition: S.ValueCondition | null;
  readonly path: readonly V.PathStep[];
};
interface VectorCase {
  readonly id: string;
  readonly input: unknown;
  readonly expected: Outcome;
}
interface VectorBranch {
  readonly id: string;
  readonly profile: string;
  readonly type_graph: string;
  readonly cases: readonly VectorCase[];
}
interface Vectors {
  readonly schema: string;
  readonly profiles: Readonly<Record<string, S.ValueSemanticProfile>>;
  readonly type_graphs: Readonly<Record<string, { readonly root: string; readonly nodes: S.TypeSignatureLibrary["nodes"] }>>;
  readonly branches: readonly VectorBranch[];
}
const vectors = JSON.parse(readFileSync(new URL("../../comparison/declaration/wrapper_base64_vectors.json", import.meta.url), "utf8")) as Vectors;
const cases = vectors.branches.flatMap(branch => branch.cases.map(testCase => ({ ...testCase, branch })));
function checkedGraph(profile: string, graph: string): { readonly context: V.ValueContext; readonly root: V.TypeRef } {
  const typeGraph = vectors.type_graphs[graph]!;
  const checked = S.checkLibrary({
    schema: "ncoh-type-signatures@1", identity: "wrapper-base64", revision: "1",
    profile: vectors.profiles[profile]!, nodes: typeGraph.nodes,
    definitions: [], sources: [], provenance: [], groups: [], annotations: [],
  });
  return { context: checked.context, root: checked.refs.get(typeGraph.root)! };
}
function outcome(context: V.ValueContext, root: V.TypeRef, input: V.ExactJson): Outcome {
  try {
    context.validate(root, input);
    return { accepted: true, condition: null, path: [] };
  } catch (error) {
    if (!(error instanceof V.SemanticValueError)) throw error;
    const separator = error.failure.condition.indexOf(":");
    const condition = separator < 0 ? { tag: error.failure.condition }
      : { tag: error.failure.condition.slice(0, separator), value: error.failure.condition.slice(separator + 1) };
    return {
      accepted: false, condition,
      path: error.failure.path.map(step => typeof step === "bigint"
        ? { tag: "Index", value: step.toString() } : { tag: "Field", value: step }),
    };
  }
}

it("loads all 55 Lean wrapper and base64 cases across 25 branches", () => {
  expect(vectors.schema).toBe("wrapper-base64-vectors@1");
  expect(vectors.branches).toHaveLength(25);
  expect(new Set(vectors.branches.map(branch => branch.id)).size).toBe(25);
  expect(cases).toHaveLength(55);
  expect(new Set(cases.map(testCase => testCase.id)).size).toBe(55);
});

it.each(cases)("matches Lean acceptance, condition arguments, and path for $id", ({ branch, input, expected }) => {
  const { context, root } = checkedGraph(branch.profile, branch.type_graph);
  const value = V.parseExact(JSON.stringify(input));
  expect(outcome(context, root, value)).toEqual(expected);
  if (branch.type_graph === "bytes") {
    if (expected.accepted) {
      const payload = V.member(value, "bytes");
      if (payload?.tag !== "String") throw new Error("expected a bytes payload");
      const decoded = V.base64Decode(payload.value, context.profile.bytes_policy!);
      expect(V.bytesValue(value, context)).toEqual(decoded);
      expect(V.wrapDecode(context.profile, "bytes", value)).toEqual(decoded);
    } else {
      expect(() => V.bytesValue(value, context)).toThrow(V.SemanticEvidenceError);
      expect(() => V.wrapDecode(context.profile, "bytes", value)).toThrow(V.SemanticEvidenceError);
    }
  }
});

it.each(["YQ==\n", "YQ==\r\n", "YQ==\r", "YQ==x", "YWJj=\n"])("rejects every character after base64 padding in %j", text => {
  const { context, root } = checkedGraph("default", "bytes");
  const value = V.toExact({ bytes: text });
  expect(V.base64Decode(text, context.profile.bytes_policy!)).toBeNull();
  expect(outcome(context, root, value)).toEqual({ accepted: false, condition: { tag: "InvalidBytes" }, path: [] });
  expect(() => V.bytesValue(value, context)).toThrow(V.SemanticEvidenceError);
});

it.each([
  { graph: "string-text", input: { text: 1 }, path: [] },
  { graph: "sealed", input: { kind: "sealed", label: { text: 1 } }, path: [{ tag: "Field", value: "label" }] },
  { graph: "unknown", input: [{ label: { text: 1 } }], path: [{ tag: "Index", value: "0" }, { tag: "Field", value: "label" }] },
])("retains the named wrapper format for a malformed payload in $graph", ({ graph, input, path }) => {
  const { context, root } = checkedGraph("wrapper-format", graph);
  expect(outcome(context, root, V.parseExact(JSON.stringify(input)))).toEqual({
    accepted: false, condition: { tag: "Format", value: "wrapper-format" }, path,
  });
});

it("preserves required sealed fields before validating wrapper refinements", () => {
  const { context: base, root } = checkedGraph("sealed-text-wrapper", "sealed");
  const leaf = base.profile.tag!.sealed[0]!.fields[0]!.leaf;
  const context = new V.ValueContext({
    ...base.graph,
    nodes: base.graph.nodes.map(node => node.shape.tag === "Sealed"
      ? { ...node, shape: { tag: "Sealed", fields: { ...node.shape.fields, refinements: [{ key: "label", leaf }] } } }
      : node),
  });
  expect(outcome(context, root, V.toExact({ kind: "sealed", label: { text: "hello" } }))).toEqual({
    accepted: true, condition: null, path: [],
  });
  expect(outcome(context, root, V.toExact({ kind: "sealed" }))).toEqual({
    accepted: false, condition: { tag: "MissingRequired" }, path: [{ tag: "Field", value: "label" }],
  });
});

it("validates wrappers in extra fields of Unknown sealed values", () => {
  const { context: base, root } = checkedGraph("default", "unknown");
  const context = new V.ValueContext({
    ...base.graph,
    profile: {
      ...base.profile,
      tag: { ...base.profile.tag!, sealed: base.profile.tag!.sealed.map(form => ({ ...form, extras: { tag: "Any" } })) },
    },
  });
  expect(outcome(context, root, V.toExact({ kind: "sealed", label: { text: "hello" }, extra: [{ bytes: "!" }] }))).toEqual({
    accepted: false, condition: { tag: "InvalidBytes" }, path: [{ tag: "Field", value: "extra" }, { tag: "Index", value: "0" }],
  });
  expect(outcome(context, root, V.toExact({ kind: "sealed", label: { text: "hello" }, extra: [{ bytes: "+_8=" }] }))).toEqual({
    accepted: true, condition: null, path: [],
  });
});
