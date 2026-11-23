// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import inspector from "node:inspector";
import { pathToFileURL } from "node:url";
import * as N from "../../../packages/typescript/adapter/src/network-effect.js";

type Any = any;
const [modulePath, runsText] = process.argv.slice(2);
const runs = Number(runsText);
const components: Record<string, readonly (readonly [string, string])[]> = {
  decode: [["/adapter/src/semantic_signatures.ts", "decodeGenerationInput"]],
  sha256: [["/adapter/src/semantic_values.ts", "hashUtf8"]],
  checkLibrary: [["/adapter/src/semantic_signatures.ts", "checkLibrary"]],
  graph: [["/adapter/src/semantic_signatures.ts", "graphProjection"], ["/adapter/src/semantic_signatures.ts", "convertShape"]],
  preparation: [["/adapter/src/semantic_signatures.ts", "admitSignatureComposition"], ["/adapter/src/signature_composition_wire.ts", "prepare"]],
  admit: [["neco-quotient-certificate", "admit"]],
  blocks: [["/dist/application.js", "keyedBlocksOf"]],
};

const initializationComponents: Record<string, readonly (readonly [string, string])[]> = {
  basis: [["/adapter/src/semantic_signatures.ts", "signatureBasis"]],
  composition: [["/adapter/src/semantic_signatures.ts", "admitSignatureComposition"]],
  sha256: [["/adapter/src/semantic_values.ts", "hashUtf8"]],
};
const session = new inspector.Session();
session.connect();
const post = (method: string, parameters?: object): Promise<Any> => new Promise((resolve, reject) => session.post(method, parameters, (error, result) => error ? reject(error) : resolve(result)));
const G: Any = await import(pathToFileURL(modulePath!).href);
await post("Profiler.enable");
await post("Profiler.startPreciseCoverage", { callCount: true, detailed: false });
await post("Profiler.takePreciseCoverage");
const initialized = G.initialize();
const { result: initialization } = await post("Profiler.takePreciseCoverage");
await post("Profiler.stopPreciseCoverage");
const init: Record<string, number> = Object.fromEntries(Object.keys(initializationComponents).map(name => [name, 0]));
for (const script of initialization) {
  if (!script.url.startsWith("file://")) continue;
  for (const fn of script.functions)
    for (const [name, owners] of Object.entries(initializationComponents))
      if (owners.some(([url, functionName]) => script.url.includes(url) && fn.functionName === functionName)) init[name]! += fn.ranges[0].count;
}
if (initialized.tag !== "Initialized") throw new Error(`initialization failed: ${JSON.stringify(initialized.failure)}`);
const runOnce = () => {
  const result = G.run(initialized.initialized, { call0: () => ({ tag: "Ok", value: { tag: "K0", values: [true] } }) }, { argument0: true }, N.emptyNetworkState());
  if (result.tag !== "Ok" || result.value.tag !== "Completed") throw new Error(`run did not complete: ${JSON.stringify(result)}`);
  return result;
};
runOnce();

await post("Profiler.startPreciseCoverage", { callCount: true, detailed: false });
await post("Profiler.takePreciseCoverage");
for (let index = 0; index < runs; index++) runOnce();
const { result: coverage } = await post("Profiler.takePreciseCoverage");
await post("Profiler.stopPreciseCoverage");
const calls: Record<string, number> = Object.fromEntries(Object.keys(components).map(name => [name, 0]));
let quantity = 0;
for (const script of coverage) {
  if (!script.url.startsWith("file://")) continue;
  for (const fn of script.functions) {
    const count = fn.ranges[0].count;
    quantity += count;
    for (const [name, owners] of Object.entries(components))
      if (owners.some(([url, functionName]) => script.url.includes(url) && fn.functionName === functionName)) calls[name]! += count;
  }
}

console.error(JSON.stringify({ calls, init, quantity: quantity / runs }));
await post("HeapProfiler.enable");
let second = 0;
for (let index = 0; index < runs; index++) {
  await post("HeapProfiler.startSampling", { samplingInterval: 1, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
  runOnce();
  const { profile } = await post("HeapProfiler.stopSampling");
  const visit = (node: Any): void => { second += node.selfSize; for (const child of node.children) visit(child); };
  visit(profile.head);
}
console.log(JSON.stringify({ calls, init, quantity: quantity / runs, second: second / runs }));
