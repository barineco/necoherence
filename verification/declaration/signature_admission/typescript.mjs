// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

import { readFileSync } from "node:fs";
import { semanticSignatures as S, semanticValues as V } from "../../../packages/typescript/adapter/dist/index.js";

const CONDITIONS = ["decode", "source", "coordinate", "observations", "digest", "residual"];
const STATUS_NAMES = { matched: "Matched", mismatched: "Mismatched", unchecked_by_decode: "UncheckedByDecode", unchecked_by_source: "UncheckedBySource" };
const PROJECTION_NAMES = { matched: "matched", certificate_only: "certificateOnly", recomputed_only: "recomputedOnly", different: "different" };

function certificateDetail(mismatch) {
  const conditions = Object.fromEntries(CONDITIONS.map(condition => [condition, STATUS_NAMES[mismatch.statusAt(condition).kind]]));
  const checks = mismatch.checks;
  const decodeFailures = checks.decode.kind === "failed" ? [checks.decode.failure] : [];
  const digests = checks.decode.kind === "established"
    ? Object.fromEntries(checks.decode.children.entries().map(([name, result]) => [name, PROJECTION_NAMES[result.kind]]))
    : null;
  const source = checks.source;
  const sourceFailures = source.kind === "failed"
    ? [source.failure]
    : ["coordinate", "observations", "residual"].flatMap(name => {
      const result = source.children[name];
      return result.kind === "mismatched" ? [result.failure] : [];
    });
  return {
    kind: "certificate",
    conditions,
    digests,
    failures: [...decodeFailures, ...sourceFailures].map(failure => ({ condition: failure.condition, operation: failure.operation })),
    origin: {
      rule_revision: mismatch.origin.ruleRevision,
      source_identity: mismatch.origin.sourceIdentity,
      source_revision: mismatch.origin.sourceRevision,
    },
    provenance: mismatch.provenance,
  };
}

function reasonName(tag) { return tag.charAt(0).toLowerCase() + tag.slice(1); }
function decodeDetail(failure) {
  if (failure.tag === "Json") return { kind: "decode", reason: "exchange_json" };
  if (failure.value.tag === "UnsupportedSchema") return { kind: "schema", actual: failure.value.value };
  return { kind: "decode", reason: `exchange.${reasonName(failure.value.tag)}` };
}
function failureDetail(failure) {
  switch (failure.tag) {
    case "EntrypointsEmpty": return { kind: "entrypoints_empty" };
    case "EntrypointIdentityEmpty": return { kind: "entrypoint_identity_empty" };
    case "EntrypointDuplicate": return { kind: "entrypoint_duplicate", identity: failure.value.identity };
    case "EntrypointUnresolved": return { kind: "entrypoint_unresolved", identity: failure.value.identity, definition: failure.value.definition };
    case "Library": return { kind: "declaration", reason: failure.value.predicate.toLowerCase() };
    case "Certificate": return certificateDetail(failure.value);
    case "CompositionInput": return { kind: "composition", reason: reasonName(failure.value.tag) };
    case "Wire": return { kind: "composition", reason: reasonName(failure.value.tag) };
    case "Decode": return decodeDetail(failure.value);
  }
}
function admissionFailureJson(failure) { return { result: "failed", failure: failureDetail(failure) }; }
function admissionAcceptedJson(checked) {
  const input = checked.input, basis = input.basis;
  return {
    result: "accepted",
    checked: {
      basis: {
        signature_schema: basis.signature_schema,
        library_identity: basis.library_identity,
        library_revision: basis.library_revision,
        profile: basis.profile,
        graph_sha256: basis.graph_sha256,
        provenance_sha256: basis.provenance_sha256,
        metadata_sha256: basis.metadata_sha256,
        problem_sha256: basis.problem_sha256,
        observations_sha256: basis.observations_sha256,
        entrypoints_sha256: basis.entrypoints_sha256,
      },
      library: { identity: input.signatures.identity, revision: input.signatures.revision },
      entrypoints: [...input.entrypoints]
        .sort((left, right) => V.codePointOrder(left.identity, right.identity))
        .map(entry => ({ identity: entry.identity, definition: entry.definition })),
      composition: input.composition === null ? null : { problem_sha256: basis.problem_sha256 },
    },
  };
}

function request(reason) { return { result: "failed", failure: { kind: "request", reason } }; }
function isRecord(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function lowerCamel(tag) { return tag.charAt(0).toLowerCase() + tag.slice(1); }

function admission(expected, exchange) {
  const admitted = S.admitSignatureGeneration(expected, exchange);
  return admitted.tag === "Admitted" ? admissionAcceptedJson(admitted.checked) : admissionFailureJson(admitted.failure);
}

function requestMode(input) {
  if (!Object.hasOwn(input, "mode")) return "admission";
  return input.mode === "admission" ? input.mode : null;
}

function run(text) {
  let input;
  try { input = JSON.parse(text); } catch { return request("request_json"); }
  if (!isRecord(input) || typeof input.exchange !== "string") return request("request_exchange");
  if (!Object.hasOwn(input, "expected_basis")) return request("request_expected_basis");
  let expected;
  try { expected = S.decodeExpectedBasisWire(input.expected_basis); }
  catch (error) {
    if (!(error instanceof V.WireError)) throw error;
    return request(`expected_basis.${lowerCamel(error.failure.tag)}`);
  }
  const mode = requestMode(input);
  if (mode === null) return request("request_mode");
  return admission(expected, input.exchange);
}

function render(text) { return JSON.stringify(run(text)); }
function renderGuarded(text) {
  try { return render(text); }
  catch (error) { return JSON.stringify({ error: `${error instanceof Error ? error.name : "Error"}: ${error instanceof Error ? error.message : String(error)}` }); }
}

if (process.argv.slice(2).join(" ") === "--batch") {
  let pending = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) {
    pending += chunk;
    let end = pending.indexOf("\n");
    while (end >= 0) {
      process.stdout.write(`${renderGuarded(pending.slice(0, end))}\n`);
      pending = pending.slice(end + 1);
      end = pending.indexOf("\n");
    }
  }
  if (pending !== "") process.stdout.write(`${renderGuarded(pending)}\n`);
} else {
  process.stdout.write(`${render(readFileSync(0, "utf8"))}\n`);
}
