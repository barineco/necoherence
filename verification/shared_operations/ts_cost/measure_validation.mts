// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import inspector from "node:inspector";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const [quantity, operation, countText] = process.argv.slice(2);
const nodeCount = Number(countText);
const REPETITIONS = 200;
const dist = new URL("../../../packages/typescript/adapter/dist/", import.meta.url);
const values: any = await import(new URL("semantic_values.js", dist).href);

const digest = "a".repeat(64);
const reference = { identity: "cost", revision: "1", content_digest: digest };
const source = { repository: "cost", revision: "1", path: "types", content_digest: digest, document_id: "", declared_revision: null };
const ref = (name: string) => ({ source, definition_name: name, pointer: [] });
const node = (name: string, shape: unknown) => ({ reference: ref(name), shape, description: null, attributes: [], extensions: [] });
const stringSpec = (overrides: object = {}) => ({ format: null, lengths: [], wrapper: null, const_value: null, enum_values: null, examples: [], default_value: null, ...overrides });
const integerSpec = (overrides: object = {}) => ({ domain: "small", minimum: null, maximum: null, const_value: null, enum_values: null, default_value: null, ...overrides });
const dfa = { tag: "AsciiDfa", value: { state_count: "2", initial_state: "0", accepting_states: ["1"], transitions: [
  { from_state: "0", first: "97", last: "122", to_state: "1" }, { from_state: "1", first: "97", last: "122", to_state: "1" }] } };
const profile = {
  reference, source_refs: [],
  integer_domains: [{ name: "small", reference, range: { tag: "Inclusive", fields: { minimum: "0", maximum: "100" } }, forms: [{ tag: "Number" }] }],
  default_integer_domain: "small", numbers: { decimals: true },
  grapheme_rules: { reference, component: { unicode_version: "15.1.0", uax29_revision: "45", cluster_profile: "extended" }, table_sha256: digest, sources: [],
    properties: [{ first: "769", last: "769", property: { tag: "Extend" } }], extended_pictographic: [], indic_conjunct: [] },
  format_bindings: [{ name: "letters", reference, rule: dfa }],
  bytes_policy: null, wrappers: [],
  tag: { key: "kind", format: null, sealed: [{ tag: "sealed", fields: [{ key: "name", required: true, leaf: { tag: "String", value: stringSpec({ format: { tag: "Named", value: "letters" } }) } }], extras: { tag: "Reject" } }] },
};
const field = (name: string, type: string, required = true) => ({ wire_name: name, slot: { type_ref: ref(type), required, nullable: false }, origin: { source, pointer: [] } });
const bounded = { tag: "Bounded", fields: { unit: { tag: "Graphemes" }, maximum: "3", rule: dfa } };

function graphOf(size: number, extra: readonly unknown[] = []) {
  const nodes = [
    node("letters", { tag: "String", value: stringSpec({ format: { tag: "Named", value: "letters" }, lengths: [{ unit: { tag: "Graphemes" }, minimum: null, maximum: "5" }] }) }),
    node("inline", { tag: "String", value: stringSpec({ format: { tag: "Inline", value: bounded } }) }),
    node("count", { tag: "Integer", value: integerSpec({ minimum: "1", maximum: "50", enum_values: ["1", "5", "50"] }) }),
    node("list", { tag: "Array", value: { item: { type_ref: ref("letters"), nullable: false }, min_length: null, max_length: "4" } }),
    node("alias", { tag: "Alias", fields: { target: ref("list"), reference_text: "list" } }),
    node("kind", { tag: "Sealed", fields: { tag: "sealed", refinements: [] } }),
    node("choice", { tag: "TaggedUnion", value: { branches: [{ target: ref("kind"), wire_tag: "sealed", selector: { tag: "InternalTag" }, origin: { source, pointer: [] } }] } }),
    node("record", { tag: "Product", value: {
      fields: [field("name", "letters"), field("inline", "inline"), field("count", "count"), field("items", "alias", false), field("choice", "choice", false)],
      extras: { tag: "Allow", fields: { key_format: { tag: "Named", value: "letters" }, value: { type_ref: ref("count"), nullable: false } } } } }),
  ];
  for (let index = 0; index < size; index += 1) nodes.push(node(`filler-${index}`, { tag: "Alias", fields: { target: ref(`filler-${(index + 1) % size}`), reference_text: "next" } }));
  nodes.push(...extra as typeof nodes);
  return values.deepFreeze({ profile, nodes });
}
const accepted = values.parseExact(JSON.stringify({ name: "ab", inline: "abc", count: 5, items: ["ab", "cd"], choice: { kind: "sealed", name: "xy" }, extra: 5 }));
const rejected = values.parseExact(JSON.stringify({ name: "ab", inline: "abcd", count: 5 }));
const slot = { type_ref: ref("record"), required: true, nullable: false };

function build(size: number): (index: number) => void {
  const context = new values.ValueContext(graphOf(size));
  const operations: Record<string, (index: number) => void> = {
    vv_validate_value: (index) => {
      const result = values.validateValue(context, ref("record"), index % 2 === 0 ? accepted : rejected);
      if ((result.tag === "Ok") !== (index % 2 === 0)) throw new Error("unexpected validation result");
    },
    vv_accepts_slot: (index) => {
      const decision = values.acceptsSlot(context, slot, { tag: "Present", value: index % 2 === 0 ? accepted : rejected });
      if ((decision.tag === "Accepted") !== (index % 2 === 0)) throw new Error("unexpected slot decision");
    },
  };
  const run = operations[operation];
  if (run === undefined) throw new Error(`unknown operation ${operation}`);
  return run;
}

const session = new inspector.Session();
session.connect();
const post = (method: string, params?: object): Promise<any> => new Promise((resolve, reject) => {
  session.post(method, params, (error: Error | null, result: unknown) => (error ? reject(error) : resolve(result)));
});

function selfSizes(head: any): number {
  let total = head.selfSize;
  for (const child of head.children) total += selfSizes(child);
  return total;
}

async function countCalls(): Promise<number> {
  const run = build(nodeCount);
  await post("Profiler.enable");
  await post("Profiler.startPreciseCoverage", { callCount: true, detailed: false });
  await post("Profiler.takePreciseCoverage");
  for (let index = 0; index < REPETITIONS; index += 1) run(index);
  const { result } = await post("Profiler.takePreciseCoverage");
  let calls = 0;
  for (const script of result) {
    if (!script.url.includes("/adapter/dist/")) continue;
    for (const entry of script.functions) calls += entry.ranges[0].count;
  }
  return calls;
}

async function sampleBytes(): Promise<number> {
  const warm = build(256);
  for (let index = 0; index < 200; index += 1) warm(index);
  const run = build(nodeCount);
  await post("HeapProfiler.enable");
  await post("HeapProfiler.startSampling", { samplingInterval: 1, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
  for (let index = 0; index < REPETITIONS; index += 1) run(index);
  const { profile: sampled } = await post("HeapProfiler.stopSampling");
  return selfSizes(sampled.head);
}

const PREPARATION_FUNCTIONS = [
  { name: "typeIdentity", prefix: "function typeIdentity(", role: "identity" },
  { name: "buildDfaTable", prefix: "function buildDfaTable(", role: "table" },
  { name: "compileFormatProgram", prefix: "function compileFormatProgram(", role: "table" },
  { name: "buildGraphemeTables", prefix: "function buildGraphemeTables(", role: "table" },
  { name: "membership", prefix: "function membership(", role: "entry" },
  { name: "meaningObligations", prefix: "meaningObligations(refs)", role: "obligation" },
];

async function preparedChecks(): Promise<{ readonly failures: string[]; readonly observed: Record<string, Record<string, number>> }> {
  const failures: string[] = [];
  const observed: Record<string, Record<string, number>> = {};
  const scriptUrl = new URL("semantic_values.js", dist).href;
  const source = readFileSync(fileURLToPath(scriptUrl), "utf8");
  await post("Profiler.enable");
  await post("Profiler.startPreciseCoverage", { callCount: true, detailed: false });
  await post("Profiler.takePreciseCoverage");
  async function counts(): Promise<Record<string, number>> {
    const { result } = await post("Profiler.takePreciseCoverage");
    const found: Record<string, number> = {};
    for (const script of result) {
      if (script.url !== scriptUrl) continue;
      for (const entry of script.functions) {
        for (const wanted of PREPARATION_FUNCTIONS) {
          if (entry.functionName !== wanted.name) continue;
          const start = entry.ranges[0].startOffset;
          if (!source.slice(start, start + wanted.prefix.length + 16).includes(wanted.prefix)) continue;
          if (wanted.name in found) failures.push(`${wanted.name}: found more than once in the coverage of ${scriptUrl}`);
          found[wanted.name] = entry.ranges[0].count;
        }
      }
    }
    return found;
  }
  const expectCount = (phase: string, found: Record<string, number>, name: string, expected: number, relation: "equal" | "atLeast" = "equal"): void => {
    const actual = found[name] ?? 0;
    if (relation === "equal" ? actual !== expected : actual < expected) failures.push(`${phase}: ${name} was called ${actual} times, expected ${relation === "equal" ? "" : "at least "}${expected}`);
  };
  const tables = PREPARATION_FUNCTIONS.filter(entry => entry.role === "table").map(entry => entry.name);

  const buildAll = (extra: readonly unknown[]) => new values.ValueContext(graphOf(40, extra));
  const stringNode = (name: string, spec: object) => node(name, { tag: "String", value: stringSpec(spec) });
  const holders = [
    stringNode("fallback", { default_value: "fallback" }),
    node("fallback-alias", { tag: "Alias", fields: { target: ref("fallback"), reference_text: "fallback" } }),
    node("holder", { tag: "Product", value: { fields: [field("slot", "fallback-alias", false), field("other", "fallback", false)], extras: { tag: "Reject" } } }),
    node("holders", { tag: "Array", value: { item: { type_ref: ref("holder"), nullable: false }, min_length: null, max_length: null } }),
  ];
  const unresolved = [
    node("blocked", { tag: "Product", value: { fields: [field("gone", "gone")], extras: { tag: "Reject" } } }),
    node("outer", { tag: "Alias", fields: { target: ref("blocked"), reference_text: "blocked" } }),
  ];

  await counts();
  const context = buildAll([...holders, ...unresolved]);
  const built = await counts();
  observed.build = built;
  for (const name of tables) expectCount("build", built, name, 1, "atLeast");
  expectCount("build", built, "typeIdentity", 1, "atLeast");

  const optional = { type_ref: ref("record"), required: false, nullable: true };
  const variants = [
    { name: "AB", inline: "abc", count: 5 },
    { name: "ab", inline: "abcd", count: 5 },
    { name: "ab", inline: "abc", count: 6 },
    { name: "ab", inline: "abc", count: 5, extra: 7 },
    { name: "ab", inline: "abc", count: 5, items: ["ab", "CD"] },
  ].map(item => values.parseExact(JSON.stringify(item)));
  const round = (): { calls: number; memberships: number } => {
    let calls = 0, memberships = 0;
    for (let repeat = 0; repeat < 3; repeat += 1) {
      if (values.validateValue(context, ref("record"), accepted).tag !== "Ok") throw new Error("accepted value was not accepted");
      if (values.acceptsValue(context, ref("record"), accepted).tag !== "Accepted") throw new Error("accepted value was not accepted");
      if (values.acceptsSlot(context, { ...optional, required: true }, { tag: "Present", value: accepted }).tag !== "Accepted") throw new Error("accepted slot was not accepted");
      if (values.acceptsSlot(context, optional, { tag: "Absent" }).tag !== "Accepted") throw new Error("absent slot was not accepted");
      if (values.acceptsSlot(context, optional, { tag: "Null" }).tag !== "Accepted") throw new Error("null slot was not accepted");
      calls += 5;
      memberships += 3;
      for (const value of variants) {
        if (values.acceptsValue(context, ref("record"), value).tag !== "Rejected") throw new Error("rejected value was not rejected");
        calls += 1;
        memberships += 1;
      }
    }
    return { calls, memberships };
  };
  const { calls, memberships } = round();
  const repeated = await counts();
  observed.repeated = repeated;
  for (const name of tables) expectCount("repeated validation", repeated, name, 0);
  expectCount("repeated validation", repeated, "meaningObligations", 0);
  expectCount("repeated validation", repeated, "membership", memberships);
  expectCount("repeated validation", repeated, "typeIdentity", calls);

  const reference = values.parseExact("{}");
  const remaining = 3;
  for (let index = 0; index < remaining; index += 1) {
    const result = values.validateValue(context, ref("outer"), reference);
    if (result.tag !== "Failed" || result.failure.tag !== "Unresolved") throw new Error("reference with remaining obligations did not fail as unresolved");
  }
  const obligations = await counts();
  observed.obligations = obligations;
  for (const name of tables) expectCount("remaining obligations", obligations, name, 0);
  expectCount("remaining obligations", obligations, "meaningObligations", remaining);

  const input = values.parseExact("[{}, {\"slot\": \"given\"}, {}]");
  const materializations = 4;
  for (let index = 0; index < materializations; index += 1) {
    if (context.materializeDefaults(ref("holders"), input).applications.length !== 5) throw new Error("unexpected default applications");
  }
  const defaulted = await counts();
  observed.defaults = defaulted;
  expectCount("default materialization", defaulted, "typeIdentity", materializations);
  for (const name of tables) expectCount("default materialization", defaulted, name, 0);

  const totals: Record<string, number> = {};
  for (const phase of Object.values(observed)) for (const [name, value] of Object.entries(phase)) totals[name] = (totals[name] ?? 0) + value;
  for (const wanted of PREPARATION_FUNCTIONS) if ((totals[wanted.name] ?? 0) < 1) failures.push(`overall: ${wanted.name} was never found in the coverage of ${scriptUrl}`);
  return { failures, observed };
}

if (quantity === "prepared") {
  const outcome = await preparedChecks();
  console.log(JSON.stringify({ quantity, operation, count: nodeCount, perOperation: outcome.failures.length, failures: outcome.failures, observed: outcome.observed }));
} else {
  const total = quantity === "calls" ? await countCalls() : await sampleBytes();
  console.log(JSON.stringify({ quantity, operation, count: nodeCount, total, perOperation: total / REPETITIONS }));
}
