// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import inspector from "node:inspector";

const [quantity, operation, countText] = process.argv.slice(2);
const count = Number(countText);
const dist = new URL("../../../packages/typescript/adapter/dist/", import.meta.url);
const core = await import(new URL("core.js", dist));
const progression = await import(new URL("request-progression.js", dist));
const storeModule = await import(new URL("store.js", dist));
const reconcileModule = await import(new URL("reconcile.js", dist));
const record = await import(new URL("record.js", dist));
const network = await import(new URL("network-effect.js", dist));
const fileEffect = await import(new URL("file-effect.js", dist));
const admission = await import(new URL("dynamic-admission.js", dist));

const resource = (index) => ({ kind: "k", name: `r${index}` });
const identity = (index) => ({ kind: "k", provenance: "p", revision: BigInt(index) });
const demand = { pending: 1n, inFlight: 1n, concurrent: 1n };
const footprint = { reads: [], writes: [], effectClass: "Pure" };
const evidence = { identifier: "e", digest: "d", artifactPath: "p" };
const limit = (name) => ({ resource: name, maximum: 1n << 60n });
const budget = { pendingMaximum: limit("p"), inFlightMaximum: limit("i"), concurrentMaximum: limit("c") };
const permission = (index) => ({ tag: "permitted", identity: identity(index), evidence: [evidence] });
const handleOf = (index) => ({ value: `h${index}` });

function entryAt(index, phase) {
  return {
    identity: identity(index),
    footprint,
    demand,
    phase,
    meaningPermission: permission(index),
    costSelection: null,
    executionHandle: phase === "Publishing" ? handleOf(index) : null,
  };
}

function progressionOf(policy, size, phase, current = null) {
  const entries = Array.from({ length: size }, (_, index) => entryAt(index, phase));
  const result = progression.snapshotOf(policy, budget, current, entries, 0n);
  if (result.tag !== "snapshot") throw new Error("snapshot rejected");
  return result.snapshot;
}

const selection = (index, tag) => ({ tag, identity: identity(index), evidence, cost: 1n });

function progressionOperation(policy, phase, step) {
  return (size) => {
    let snapshot = progressionOf(policy, size, phase, policy === "LatestWins" ? identity(size - 1) : null);
    return (index) => {
      snapshot = step(snapshot, index, size);
    };
  };
}

function networkInput(index) {
  return {
    attempt: { logical: identity(index), ordinal: 0n },
    instruction: { method: "GET", target: "https://127.0.0.1/t", headers: [], body: new Uint8Array() },
    deadline: null,
    configuration: { requestBodyLimit: 32n, responseBodyLimit: 32n, cancellation: { identity: { value: "c" } }, monotonicClock: null },
  };
}

function delivery(index, sequence) {
  return {
    tag: "Delivered",
    delivery: BigInt(sequence),
    observation: {
      tag: "ResponseObservation",
      attempt: networkInput(index).attempt,
      handle: handleOf(index),
      sourceSequence: { tag: "none" },
      response: { status: 200, headers: [], body: new Uint8Array() },
      provenance: "LibraryNormalized",
      effect: { tag: "Unknown", reason: "NoResponse" },
    },
  };
}

function networkStage(size, stage) {
  let state = network.emptyNetworkState();
  const prepared = [];
  const started = [];
  for (let index = 0; index < size; index += 1) {
    const step = network.prepare(state, networkInput(index));
    state = step.state;
    prepared.push(step.prepared);
  }
  if (stage === "prepared") return { state, prepared, started };
  for (let index = 0; index < size; index += 1) state = network.sendCommand(state, prepared[index]).state;
  if (stage === "issued") return { state, prepared, started };
  for (let index = 0; index < size; index += 1) {
    const step = network.observeStart(state, prepared[index], { tag: "Started", attempt: networkInput(index).attempt, handle: handleOf(index) });
    state = step.state;
    started.push(step.started);
  }
  if (stage === "started") return { state, prepared, started };
  for (let index = 0; index < size; index += 1) state = network.observe(state, delivery(index, 0)).state;
  return { state, prepared, started };
}

function networkOperation(stage, step) {
  return (size) => {
    const fixture = networkStage(size, stage);
    let state = fixture.state;
    return (index) => {
      state = step(state, index, size, fixture);
    };
  };
}

function retryRequest(index) {
  const logical = identity(index);
  return {
    permission: {
      tag: "RetryAllowed",
      authorization: {
        logical,
        from: { logical, ordinal: 0n },
        next: { logical, ordinal: 1n },
        protocolEvidence: { value: "p" },
      },
    },
    instruction: networkInput(index).instruction,
    deadline: null,
    configuration: networkInput(index).configuration,
  };
}

function fileEffectFixture(size) {
  const path = (index) => fileEffect.normalizePath(true, [`f${index}`]);
  const fileResource = (index) => ({ kind: "file", name: `/f${index}` });
  const digestOf = (index) => ({ value: `d${index}` });
  const last = size - 1;
  const state = fileEffect.externalFileStateOf(Array.from({ length: size }, (_, index) => [path(index), { digest: digestOf(0), bytes: [0, 0, 0, 0] }]), [], []);
  const world = core.worldOf(Array.from({ length: size }, (_, index) => [fileResource(index), { value: 0n }]));
  const digests = fileEffect.digestsOf(Array.from({ length: size }, (_, index) => [fileResource(index), digestOf(0)]));
  const replacing = Array.from({ length: size }, (_, index) => ({
    intent: { newContents: [1, 1, 1, 1], newDigest: digestOf(index + 1) },
    basis: { resource: fileResource(last), revision: { value: BigInt(index) } },
  }));
  return { path: path(last), state, world, digests, replacing };
}

function admissionState(policy, size, phase, futureUses) {
  return admission.admissionStateOf(progressionOf(policy, size, phase, identity(0)), budget, { futureUses, outstandingSignals: [] });
}

function admissionInput(state, index, size, start) {
  return {
    state,
    request: { identity: identity(size + index), footprint, demand, permission: permission(size + index) },
    environmentSpecification: { maxObservationAge: 1n },
    capacityObservation: { observed: budget, observedAt: 0n },
    observedAt: 0n,
    start,
  };
}

function admitted(state, index, size, start) {
  const outcome = admission.admitDynamicRequest(admissionInput(state, index, size, start));
  if (outcome.tag !== "Applied") throw new Error("admission rejected");
  return outcome.value.admissionDecision.state;
}

const operations = {
  core_lookup: (size) => {
    const world = core.worldOf(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }]));
    return () => core.lookup(world, resource(size - 1));
  },
  core_bump: (size) => {
    let world = core.worldOf(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }]));
    return () => {
      world = core.bump(world, resource(size - 1));
    };
  },
  core_apply: (size) => {
    let world = core.worldOf(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }]));
    let revision = BigInt(size);
    return () => {
      const outcome = core.apply(world, { intent: 0, basis: { resource: resource(size - 1), revision: { value: revision } } });
      if (outcome.tag !== "Applied") throw new Error("apply rejected");
      world = outcome.value[1];
      revision += 1n;
    };
  },
  core_apply_conflicted: (size) => {
    const world = core.worldOf(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }]));
    return () => core.apply(world, { intent: 0, basis: { resource: resource(size - 1), revision: { value: 0n } } });
  },
  core_apply_unknown: (size) => {
    const world = core.worldOf(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }]));
    return () => core.apply(world, { intent: 0, basis: { resource: resource(size + 1), revision: { value: 1n } } });
  },
  store_observe: (size) => {
    const admitted = storeModule.snapshotStore(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }, { label: `v${index}` }]));
    return () => storeModule.observe(admitted.value, resource(size - 1));
  },
  store_apply: (size) => {
    let store = storeModule.snapshotStore(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 1) }, { label: `v${index}` }])).value;
    let revision = BigInt(size);
    return (index) => {
      const outcome = storeModule.applyStore(store, { intent: { label: `v${index}` }, basis: { resource: resource(size - 1), revision: { value: revision } } });
      if (outcome.tag !== "Applied") throw new Error("applyStore rejected");
      store = outcome.value[1];
      revision += 1n;
    };
  },
  rp_submit_fifo: progressionOperation("Fifo", "Pending", (snapshot, index, size) => {
    const next = identity(size + index);
    return progression.submit(snapshot, { identity: next, footprint, demand, permission: permission(size + index) }).snapshot;
  }),
  rp_submit_latest_wins: progressionOperation("LatestWins", "Pending", (snapshot, index, size) => {
    const next = identity(size + index);
    return progression.submit(snapshot, { identity: next, footprint, demand, permission: permission(size + index) }).snapshot;
  }),
  rp_decide_start: progressionOperation("Fifo", "Pending", (snapshot, index) => {
    const result = progression.decideStart(snapshot, { identity: identity(index) }, selection(index, "executeNow"));
    if (result.tag !== "execute") throw new Error("start rejected");
    return result.snapshot;
  }),
  rp_decide_start_blocked: progressionOperation("Fifo", "Pending", (snapshot, _index, size) => {
    const result = progression.decideStart(snapshot, { identity: identity(size - 1) }, selection(size - 1, "executeNow"));
    if (result.tag !== "rejected") throw new Error("start accepted");
    return snapshot;
  }),
  rp_apply_start_observation: progressionOperation("AllExecute", "Preparing", (snapshot, index) => {
    const signal = { tag: "started", identity: identity(index), handle: handleOf(index) };
    const result = progression.applyStartObservation(snapshot, { identity: identity(index), command: { tag: "startCommand", identity: identity(index), footprint } }, { tag: "appliedSignal", signal });
    if (result.tag !== "publishing") throw new Error("start observation rejected");
    return result.snapshot;
  }),
  rp_apply_completion_observation: progressionOperation("AllExecute", "Publishing", (snapshot, index) => {
    const signal = { tag: "completed", identity: identity(index), handle: handleOf(index), value: 0 };
    const result = progression.applyCompletionObservation(snapshot, { identity: identity(index), handle: handleOf(index) }, { tag: "appliedSignal", signal });
    if (result.tag !== "applied") throw new Error("completion rejected");
    return result.snapshot;
  }),
  rp_decide_cancel: progressionOperation("AllExecute", "Pending", (snapshot, index) => {
    const result = progression.decideCancel(snapshot, identity(index));
    if (result.tag !== "cancelled") throw new Error("cancel rejected");
    return result.snapshot;
  }),
  rp_derive_pending: progressionOperation("Fifo", "Pending", (snapshot) => {
    progression.derivePending(snapshot);
    return snapshot;
  }),
  rp_derive_in_flight: progressionOperation("Fifo", "Preparing", (snapshot) => {
    progression.deriveInFlight(snapshot);
    return snapshot;
  }),
  rp_derive_concurrent: progressionOperation("Fifo", "Publishing", (snapshot) => {
    progression.deriveConcurrent(snapshot);
    return snapshot;
  }),
  ne_prepare: networkOperation("prepared", (state, index, size) => network.prepare(state, networkInput(size + index)).state),
  ne_send_command: networkOperation("prepared", (state, index, _size, fixture) => network.sendCommand(state, fixture.prepared[index]).state),
  ne_observe_start: networkOperation("issued", (state, index, _size, fixture) =>
    network.observeStart(state, fixture.prepared[index], { tag: "Started", attempt: networkInput(index).attempt, handle: handleOf(index) }).state),
  ne_cancel_command: networkOperation("started", (state, index, _size, fixture) => network.cancelCommand(state, fixture.started[index]).state),
  ne_observe_pending: networkOperation("started", (state, index) =>
    network.observe(state, { tag: "Pending", attempt: networkInput(index).attempt, handle: handleOf(index) }).state),
  ne_observe_delivered: networkOperation("started", (state, index) => network.observe(state, delivery(index, 0)).state),
  ne_observe_late: networkOperation("settled", (state, index) => network.observe(state, delivery(index, 1)).state),
  ne_annotate_effect: networkOperation("settled", (state, index) => {
    const attempt = networkInput(index).attempt;
    return network.annotateEffect(state, { attempt, status: { tag: "NoEffect", witness: { attempt, source: "Adapter", evidence: { value: "e" } } } }).state;
  }),
  ne_retry: networkOperation("settled", (state, index) => network.retry(state, retryRequest(index)).state),
  ne_read_network_state: networkOperation("settled", (state) => network.readNetworkState(state).state),
  file_effect_read: (size) => {
    const fixture = fileEffectFixture(size);
    let held = { world: fixture.world, digests: fixture.digests };
    return (index) => {
      const outcome = fileEffect.read({ path: fixture.path, world: held.world, digests: held.digests, state: fixture.state, observedAt: BigInt(index) });
      if (outcome.tag !== "Applied") throw new Error("read rejected");
      held = { world: outcome.value.world, digests: outcome.value.digests };
    };
  },
  file_effect_replace: (size) => {
    const fixture = fileEffectFixture(size);
    let held = { world: fixture.world, digests: fixture.digests, state: fixture.state };
    return (index) => {
      const outcome = fileEffect.replace({ command: fixture.replacing[index], path: fixture.path, world: held.world, digests: held.digests, state: held.state, observedAt: BigInt(index) });
      if (outcome.tag !== "Applied") throw new Error("replace rejected");
      held = { world: outcome.value.world, digests: outcome.value.digests, state: outcome.value.state };
    };
  },
  file_effect_track: (size) => {
    const fixture = fileEffectFixture(size);
    let world = fixture.world;
    return (index) => {
      const outcome = fileEffect.track({ path: fileEffect.normalizePath(true, [`f${size + index}`]), world, observedAt: BigInt(index) });
      if (outcome.tag !== "Applied") throw new Error("track rejected");
      world = outcome.value.world;
    };
  },
  da_admit_submitted: (size) => {
    let state = admissionState("Fifo", size, "Pending", []);
    return (index) => {
      state = admitted(state, index, size, null);
    };
  },
  da_admit_executed: (size) => {
    let state = admissionState("AllExecute", size, "Pending", []);
    return (index) => {
      state = admitted(state, index, size, { tag: "executeNow", identity: identity(size + index), evidence, cost: 0n });
    };
  },
  da_elide_admission_provenance: (size) => {
    let state = admissionState("Fifo", size, "Cancelled", Array.from({ length: size }, (_, index) => identity(2 * size + index)));
    return (index) => {
      const outcome = admission.elideAdmissionProvenance(state, identity(index));
      if (outcome.tag !== "Applied") throw new Error("elide rejected");
      state = outcome.value[0];
    };
  },
};

const wholeScans = {
  reconcile: (size) => {
    const world = core.worldOf(Array.from({ length: size }, (_, index) => [resource(index), { value: BigInt(index + 2) }]));
    const bases = Array.from({ length: size }, (_, index) => record.withBasis({ resource: resource(index), revision: { value: BigInt(index + 1) } }));
    return () => reconcileModule.reconcile(bases, world, 0n);
  },
};

const isScan = Object.hasOwn(wholeScans, operation);
const build = isScan ? wholeScans[operation] : operations[operation];
if (build === undefined) throw new Error(`unknown operation ${operation}`);
const repetitions = isScan ? 1 : count;

const session = new inspector.Session();
session.connect();
const post = (method, params) => new Promise((resolve, reject) => {
  session.post(method, params, (error, result) => (error ? reject(error) : resolve(result)));
});

function selfSizes(node) {
  let total = node.selfSize;
  for (const child of node.children) total += selfSizes(child);
  return total;
}

async function countCalls() {
  const run = build(count);
  await post("Profiler.enable");
  await post("Profiler.startPreciseCoverage", { callCount: true, detailed: false });
  await post("Profiler.takePreciseCoverage");
  for (let index = 0; index < repetitions; index += 1) run(index);
  const { result } = await post("Profiler.takePreciseCoverage");
  let calls = 0;
  for (const script of result) {
    if (!script.url.includes("/adapter/dist/")) continue;
    for (const entry of script.functions) calls += entry.ranges[0].count;
  }
  return calls;
}

async function sampleBytes() {
  const warm = build(256);
  for (let index = 0; index < 200; index += 1) warm(index);
  const run = build(count);
  await post("HeapProfiler.enable");
  const chunk = 100;
  let bytes = 0;
  for (let start = 0; start < repetitions; start += chunk) {
    await post("HeapProfiler.startSampling", { samplingInterval: 1, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
    for (let index = start; index < Math.min(start + chunk, repetitions); index += 1) run(index);
    const { profile } = await post("HeapProfiler.stopSampling");
    bytes += selfSizes(profile.head);
  }
  return bytes;
}

const total = quantity === "calls" ? await countCalls() : await sampleBytes();
const divisor = isScan ? count : repetitions;
console.log(JSON.stringify({ quantity, operation, count, total, perOperation: total / divisor }));
