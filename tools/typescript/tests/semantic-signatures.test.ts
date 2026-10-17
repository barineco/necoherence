// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { expect, it } from "vitest";
import { semanticSignatures as S } from "necoherence";
import { renderSignatureGeneration } from "../src/index.js";
import { generation } from "./semantic-fixture.js";

it("compiles and exercises generated metadata, codecs, and HTTP execution", () => {
  const input = generation(), admitted = S.admitSignatureGeneration(input.basis, JSON.stringify(input));
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const generated = renderSignatureGeneration(admitted.checked, resolve("../../typescript/dist/index.js"));
  expect(generated.split("\n")[0]).toBe("// SPDX-License-" + "Identifier: MIT");
  expect(generated).not.toMatch(/from ["']necoherence-tools["']/);
  const directory = mkdtempSync(resolve(tmpdir(), "ncoh-tools-typescript-"));
  try {
    const filename = resolve(directory, "generated.mts");
    writeFileSync(filename, generated);
    execFileSync(process.execPath, [resolve("node_modules/typescript/bin/tsc"), filename, "--target", "ES2022", "--module", "NodeNext", "--strict", "--skipLibCheck"], { encoding: "utf8", stdio: "pipe" });
    const runner = resolve(directory, "runner.mjs");
    writeFileSync(runner, `import * as G from "./generated.mjs";
const fail = condition => { if (condition) throw new Error(condition); };
fail(G.signatureGraph.nodes.length !== 4 && "graph");
fail(G.annotations.length !== 2 && "annotations length");
fail(G.annotationsFor({ tag: "Library" })[0]?.value.members[0]?.value.value !== "9007199254740993" && "annotation integer");
fail(G.annotationsFor({ tag: "Library" })[0]?.value.members[1]?.value.text !== "1.000000000000000000001" && "annotation decimal");
fail(G.T_70726f64756374Codec.decode("{}").tag !== "Object" && "declared product");
let extrasRejected = false;
try { G.T_70726f64756374Codec.decode('{"undeclared":null}'); } catch { extrasRejected = true; }
fail(!extrasRejected && "undeclared member");
const external = { outcome: "external", values: { reason: { tag: "Present", value: { tag: "Null" } } } };
const success = { outcome: "ok", values: { value: { tag: "Present", value: { tag: "Null" } } } };
const input = {
  attempt: { logical: { kind: "generated", provenance: "test", revision: 1n }, ordinal: 0n },
  instruction: { method: "GET", target: "https://example.test/", headers: [], body: [] },
  deadline: null,
  configuration: { requestBodyLimit: 1024n, responseBodyLimit: 1024n, cancellation: null, monotonicClock: null },
};
let starts = 0, observations = 0, decodes = 0;
const unusedAdapter = { start() { starts++; throw new Error("unexpected start"); }, observe() { observations++; throw new Error("unexpected observation"); } };
const completed = await G.N_72657175657374Execute({}, { prepare: () => ({ tag: "Completed", value: { outcome: "external", value: external } }), decode() { throw new Error("unexpected decode"); } }, { state: { attempts: [] }, adapter: unusedAdapter });
fail(completed.tag !== "Completed" && "external completion");
fail(starts !== 0 && "synchronous start");
fail(observations !== 0 && "synchronous observation");
const premature = await G.N_72657175657374Execute({}, { prepare: () => ({ tag: "Completed", value: { outcome: "ok", value: success } }), decode() { throw new Error("unexpected decode"); } }, { state: { attempts: [] }, adapter: unusedAdapter });
fail(premature.tag !== "Rejected" && "success completion");
const mismatch = await G.N_72657175657374Execute({}, { prepare: () => ({ tag: "Completed", value: { outcome: "external", value: success } }), decode() { throw new Error("unexpected decode"); } }, { state: { attempts: [] }, adapter: unusedAdapter });
fail(mismatch.tag !== "Rejected" && "completion identity");
const adapter = {
  start(command) { starts++; return { tag: "Started", attempt: command.prepared.input.attempt, handle: { value: "generated-handle" } }; },
  observe(handle) {
    observations++;
    return { tag: "Delivered", delivery: 0n, observation: { tag: "ResponseObservation", attempt: input.attempt, handle, sourceSequence: { tag: "none" }, response: { status: 200, headers: [], body: [] }, provenance: "WireObserved", effect: { tag: "Unknown", reason: "NoResponse" } } };
  },
};
const observed = await G.N_72657175657374Execute({}, { prepare: () => ({ tag: "Ready", value: input }), decode() { decodes++; return success; } }, { state: { attempts: [] }, adapter });
fail(observed.tag !== "Completed" && "observed completion");
fail(starts !== 1 && "started once");
fail(observations !== 1 && "observed once");
fail(decodes !== 1 && "decoded once");
`);
    execFileSync(process.execPath, [runner], { encoding: "utf8", stdio: "pipe" });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

it("compiles both generated default codecs and roundtrips every declared slot", () => {
  const input = structuredClone(generation());
  const truth = input.signatures.nodes.find(node => node.id === "truth")!;
  const product = input.signatures.nodes.find(node => node.id === "product")!;
  if (truth.shape.tag !== "Boolean" || product.shape.tag !== "Product") throw new Error("fixture");
  Object.assign(truth.shape.value, { default_value: false });
  Object.assign(input.signatures, { nodes: [...input.signatures.nodes, { id: "any", shape: { tag: "Unknown", value: { tag: "Any" } } }] });
  Object.assign(product.shape.value, { fields: [
    { wire_name: "flag", slot: { type_id: "truth", required: true, nullable: false } },
    { wire_name: "seen", slot: { type_id: "truth", required: false, nullable: true } },
  ], extras: { tag: "Allow", fields: { key_format: null, value: { type_id: "any", nullable: false } } } });
  Object.assign(input, { basis: S.signatureBasis(input.signatures, input.entrypoints) });
  const admitted = S.admitSignatureGeneration(input.basis, JSON.stringify(input));
  if (admitted.tag !== "Admitted") throw new Error(JSON.stringify(admitted.failure));
  const directory = mkdtempSync(resolve(tmpdir(), "ncoh-default-typescript-"));
  try {
    const filename = resolve(directory, "generated.mts");
    writeFileSync(filename, renderSignatureGeneration(admitted.checked, resolve("../../typescript/dist/index.js")));
    execFileSync(process.execPath, [resolve("node_modules/typescript/bin/tsc"), filename, "--target", "ES2022", "--module", "NodeNext", "--strict", "--skipLibCheck"], { encoding: "utf8", stdio: "pipe" });
    const runner = resolve(directory, "runner.mjs");
    writeFileSync(runner, `import * as G from "./generated.mjs";
import { semanticValues as V } from ${JSON.stringify(resolve("../../typescript/dist/index.js"))};
const typed = G.Type_product_3Codec.decodeWithDefaults("{}");
if (typed.flag !== false || typed.seen !== false) throw new Error("declared slots");
if (V.encodeExact(G.Type_product_3Codec.encode(typed)) !== '{"flag":false,"seen":false}') throw new Error("concrete encode");
if (G.T_70726f64756374Codec.encode(G.T_70726f64756374Codec.decodeWithDefaults("{}")) !== '{"flag":false,"seen":false}') throw new Error("exact encode");
const retained = '{"2":false,"seen":null,"1":0}', expected = retained.slice(0, -1) + ',"flag":false}';
const ordered = G.Type_product_3Codec.decodeWithDefaults(retained);
if (ordered.flag !== false || ordered.seen !== null || ordered["1"] !== 0n || ordered["2"] !== false) throw new Error("ordered declared and extra slots");
if (V.encodeExact(G.Type_product_3Codec.encode(ordered)) !== expected) throw new Error("ordered concrete encode");
if (G.T_70726f64756374Codec.encode(G.T_70726f64756374Codec.decodeWithDefaults(retained)) !== expected) throw new Error("ordered exact encode");
let strict = false;
try { G.Type_product_3Codec.decode(V.parseExact("{}")); } catch { strict = true; }
if (!strict) throw new Error("strict decode");
`);
    execFileSync(process.execPath, [runner], { encoding: "utf8", stdio: "pipe" });
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
