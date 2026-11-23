# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Compares the signature admission entries of the six languages with the Lean entry (the propagation mode compares Lean and Rust).

The exchanges and the expected bases come from the signature generator. The script derives the
admission inputs, runs each language entry on every input, and compares the output with the Lean
output. The Lean output is the reference. The script fails when an output differs, when a language
entry is missing, or when the Lean output does not satisfy the expectation stated for an input.

The labels of an input name the judgement that the input serves:
accept (acceptance of a matching basis), certificate (certificate failure), non-certificate
(failure before or outside the certificate), basis-mutation (one basis field changed in the expected
basis, the exchange, or both), two-roots (schema and source identity changed together),
source-digest (source identity and graph digest changed together), projection-names (one projection
changed), problem-side (problem digest present on one side only), order-independence (entrypoints
reordered), check-order (failure order of the checks), basis-value (an empty identity, a digest that is not
a sha256 value, or a non-string field in a basis), composition-wire (a broken composition part, which the
composition kind reports), propagation (the failures that a boundary must keep), library-predicate (one library
predicate LB01 to LB19 broken per input), profile-predicate (one profile predicate PR01 to PR16 broken per
input), predicate-order (several predicates broken at once, so that the first one in the check order is
reported), decode-stage (a malformed exchange that the decode of the exchange must report before any admission
check), library-shape (an alias cycle in the library), record-keys (one extra key added to a record of the derivation, the problem, or
the library with its profile, which every record decode must report as unknownField before it reads a field).

The labels exhaustive-* name the mutation inputs of signature_admission_exhaustive.py: exhaustive-base (the
unmutated base exchange), exhaustive-single, exhaustive-natural, exhaustive-extra-name, exhaustive-pair,
exhaustive-decimal-text, exhaustive-canonical (the families of edits), exhaustive-recomputed and exhaustive-stale (whether the digests of the basis were derived
again from the edited exchange), and exhaustive-from-<base> (the base exchange). The expectation of such an
input is the Lean output itself.

Every input of a language is sent to one process with the option --batch, which prints one output line per
input line.

The mode admission (the default) compares the runtime admission entries of the six languages on every input.
The mode propagation (`--mode propagation`) compares the generator boundary of Lean and Rust only, on the inputs with
the propagation label. The Rust entry runs the generator command once per input and answers
`{"admission": ..., "boundaries": ...}`. Python, TypeScript, Java, and Gleam have no generator of their own, so the
propagation mode does not run them. The Rust entry verifies the derivation for the admission result and the generation
boundary, with the same calls as the composition solver check program, so those two values are compared with the Lean values
directly on every input. The Rust
generator does not verify the derivation, so on the inputs whose derivation fails the verification (the checks that
carry a `propagation` expectation) the generator boundary of Lean is checked against that expectation and the generator
boundary of Rust against the admission mode expectation; on the other inputs the generator boundary is compared with
the Lean value directly.
A boundary is `accepted`, or the failure of that entry with its wrapper removed, in the admission form.
"""

from __future__ import annotations

import argparse
import atexit
import copy
import dataclasses
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import signature_admission_exhaustive as exhaustive

ROOT = Path(__file__).resolve().parents[2]
ENTRY_DIR = ROOT / "verification" / "declaration" / "signature_admission"
GENERATOR_MANIFEST = ROOT / "verification" / "declaration" / "signature_generator" / "Cargo.toml"
LANGUAGES = ("lean", "python", "typescript", "java", "rust", "gleam")
PROPAGATION_LANGUAGES = ("lean", "rust")
TIMEOUT_SECONDS = 300

BASIS_FIELDS = (
    "signature_schema",
    "library_identity",
    "library_revision",
    "profile",
    "graph_sha256",
    "provenance_sha256",
    "metadata_sha256",
    "problem_sha256",
    "observations_sha256",
    "entrypoints_sha256",
)
CONDITIONS = ("decode", "source", "coordinate", "observations", "digest", "residual")
MATCHED = "Matched"
MISMATCHED = "Mismatched"
UNCHECKED_BY_SOURCE = "UncheckedBySource"
SOURCE_FIELDS = ("library_identity", "library_revision")
COORDINATE_FIELDS = ("signature_schema", "profile")
ALTERNATIVE = {
    "signature_schema": "ncoh-type-signatures@9",
    "library_identity": "mutated.signatures",
    "library_revision": "mutated-revision",
    "profile": {"identity": "mutated-profile", "revision": "1", "content_digest": "0" * 64},
    "graph_sha256": "1" * 64,
    "provenance_sha256": "3" * 64,
    "metadata_sha256": "4" * 64,
    "problem_sha256": "5" * 64,
    "observations_sha256": "8" * 64,
    "entrypoints_sha256": "6" * 64,
}


class Missing(Exception):
    pass


@dataclass
class Runner:
    argv: list[str]
    cwd: Path
    env: dict[str, str]


@dataclass
class Case:
    name: str
    request: str
    labels: set[str] = field(default_factory=set)
    checks: list[Callable[[dict, dict], str | None]] = field(default_factory=list)
    packed: bytes | None = None
    mutation: exhaustive.ExhaustiveInput | None = None
    admission_checks: list[Callable[[dict, dict], str | None]] | None = None

    def text(self) -> str:
        return self.request if self.packed is None else zlib.decompress(self.packed).decode("utf-8")


def compact(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def canonical(value) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def short(value, limit: int = 240) -> str:
    text = canonical(value)
    return text if len(text) <= limit else text[:limit] + "..."


_OBSERVED = object()


def composition_of(exchange):
    if not isinstance(exchange, str):
        return exchange.get("composition")
    try:
        parsed = json.loads(exchange)
    except ValueError:
        return None
    return parsed.get("composition") if isinstance(parsed, dict) else None


def request_text(exchange, expected, observations=_OBSERVED) -> str:
    text = exchange if isinstance(exchange, str) else compact(exchange)
    if observations is _OBSERVED:
        observations = exhaustive.goal_observations(composition_of(exchange))
    return compact({"exchange": text, "expected_basis": {"basis": expected, "observations": observations}})


def expected_conditions(field_name: str, mode: str) -> dict[str, str]:
    result = {name: MATCHED for name in CONDITIONS}
    if mode == "expected":
        if field_name in SOURCE_FIELDS:
            result.update(source=MISMATCHED, coordinate=UNCHECKED_BY_SOURCE,
                          observations=UNCHECKED_BY_SOURCE, residual=UNCHECKED_BY_SOURCE)
        else:
            result["coordinate"] = MISMATCHED
    elif mode == "declared":
        if field_name in SOURCE_FIELDS:
            result.update(source=MISMATCHED, coordinate=UNCHECKED_BY_SOURCE,
                          observations=UNCHECKED_BY_SOURCE, residual=UNCHECKED_BY_SOURCE)
        elif field_name in COORDINATE_FIELDS:
            result["coordinate"] = MISMATCHED
        else:
            result.update(coordinate=MISMATCHED, digest=MISMATCHED)
    else:
        if field_name in SOURCE_FIELDS or field_name in COORDINATE_FIELDS:
            result["coordinate"] = MISMATCHED
        else:
            result["digest"] = MISMATCHED
    return result


def failure_of(out: dict) -> dict:
    return out.get("failure", {}) if out.get("result") == "failed" else {}


def check_accepted():
    def check(out, results):
        return None if out.get("result") == "accepted" else f"expected accepted, got {short(out)}"
    return check


def check_derivation_verified(propagation):
    check = check_accepted()
    check.propagation = propagation
    return check


def check_kind(kind: str):
    def check(out, results):
        if failure_of(out).get("kind") != kind:
            return f"expected failure kind {kind}, got {short(out)}"
        return None
    return check


def check_reason(kind: str, reason: str):
    def check(out, results):
        failure = failure_of(out)
        if failure.get("kind") != kind or failure.get("reason") != reason:
            return f"expected {kind} with reason {reason}, got {short(out)}"
        return None
    return check


def check_conditions(expected: dict[str, str]):
    def check(out, results):
        failure = failure_of(out)
        if failure.get("kind") != "certificate":
            return f"expected a certificate failure, got {short(out)}"
        if failure.get("conditions") != expected:
            return f"conditions differ: expected {expected}, got {failure.get('conditions')}"
        return None
    return check


def check_digests(special: dict[str, str]):
    def check(out, results):
        digests = failure_of(out).get("digests")
        if not isinstance(digests, dict):
            return f"expected digests in the certificate failure, got {short(out)}"
        for name in special:
            if name not in digests:
                return f"digest name {name} is missing: {sorted(digests)}"
        for name, actual in digests.items():
            want = special.get(name, "matched")
            if actual != want:
                return f"digest {name}: expected {want}, got {actual}"
        return None
    return check


def check_same_as(name: str):
    def check(out, results):
        if name not in results:
            return f"reference case {name} has no Lean output"
        if canonical(out) != canonical(results[name]):
            return f"Lean output differs from {name}: {short(out)} vs {short(results[name])}"
        return None
    return check


def mutate(exchange: dict, expected: dict, field_name: str, mode: str) -> tuple[dict, dict]:
    changed_exchange = copy.deepcopy(exchange)
    changed_expected = copy.deepcopy(expected)
    value = copy.deepcopy(ALTERNATIVE[field_name])
    if mode in ("expected", "both"):
        changed_expected[field_name] = copy.deepcopy(value)
    if mode in ("declared", "both"):
        changed_exchange["basis"][field_name] = copy.deepcopy(value)
    return changed_exchange, changed_expected


def request_key(request: str) -> str:
    return hashlib.sha256(request.encode("utf-8")).hexdigest()


class Builder:
    def __init__(self) -> None:
        self.cases: list[Case] = []
        self.index: dict[str, Case] = {}

    def add(self, name: str, request: str, labels=(), checks=()) -> None:
        existing = self.index.get(request_key(request))
        if existing is not None:
            existing.labels.update(labels)
            existing.checks.extend(checks)
            return
        case = Case(name, request, set(labels), list(checks))
        self.cases.append(case)
        self.index[request_key(request)] = case

    def add_mutation(self, item: exhaustive.ExhaustiveInput, labels) -> None:
        key = request_key(item.request)
        existing = self.index.get(key)
        if existing is not None:
            existing.labels.update(labels)
            return
        case = Case(item.name, "", set(labels), [], zlib.compress(item.request.encode("utf-8"), 1),
                    dataclasses.replace(item, request=""))
        self.cases.append(case)
        self.index[key] = case

def add_text_entry_cases(builder: Builder, plain_text: str, expected_plain: dict) -> None:
    identity = '"generated.signatures"'
    revision = '"library_revision":"1"'
    if identity not in plain_text or revision not in plain_text:
        raise SystemExit("the plain exchange lacks the text that the text-entry inputs replace")
    builder.add("text-entry/lone-surrogate-identity",
                request_text(plain_text.replace(identity, '"generated\\uD800.signatures"'), expected_plain),
                {"non-certificate", "text-entry"})
    builder.add("text-entry/surrogate-pair-identity",
                request_text(plain_text.replace(identity, '"generated\\uD83D\\uDE00.signatures"'), expected_plain),
                {"non-certificate", "text-entry"})
    for name, number in (("exponent-limit", "1e10000"), ("negative-exponent-limit", "1e-10000"),
                         ("exponent-below-limit", "1e9999")):
        builder.add(f"text-entry/{name}", request_text(plain_text.replace(revision, '"library_revision":' + number, 1),
                                                        expected_plain), {"non-certificate", "text-entry"})


def add_observation_cases(builder: Builder, plain: dict, composition: dict, expected_plain: dict,
                          expected_composition: dict) -> None:
    only_observations = {name: MATCHED for name in CONDITIONS}
    only_observations["observations"] = MISMATCHED
    declared = exhaustive.goal_observations(composition["composition"])
    for name, change in (("output-removed", lambda goal: goal["outputs"].pop()),
                         ("output-contract-changed",
                          lambda goal: goal["outputs"][0]["contract"].__setitem__("nullable", True)),
                         ("failure-added", lambda goal: goal["failures"].append(
                             {"id": "declared-failure", "contract": goal["outputs"][0]["contract"],
                              "final_resources": []})),
                         ("final-resources-changed", lambda goal: goal.__setitem__("final_resources", [{"x": 1}]))):
        changed = copy.deepcopy(composition["composition"])
        change(changed["problem"]["goal"])
        observations = exhaustive.goal_observations(changed)
        if observations == declared:
            raise RuntimeError(f"the goal change {name} leaves the observations unchanged")
        builder.add(f"observations/expected-goal-{name}",
                    request_text(composition, expected_composition, observations),
                    {"certificate", "observations"}, [check_conditions(only_observations)])
    builder.add("observations/expected-absent-composition", request_text(composition, expected_composition, None),
                {"certificate", "observations"}, [check_conditions(only_observations)])
    builder.add("observations/expected-present-plain", request_text(plain, expected_plain, declared),
                {"certificate", "observations"}, [check_conditions(only_observations)])
    for side, mode in (("declared", "declared"), ("both", "both")):
        changed_exchange, changed_expected = mutate(composition, expected_composition, "observations_sha256", mode)
        changed_exchange["basis"]["observations_sha256"] = None
        if mode == "both":
            changed_expected["observations_sha256"] = None
        builder.add(f"observations-side/composition-digest-null-{side}",
                    request_text(changed_exchange, changed_expected), {"certificate", "observations-side"},
                    [check_digests({"observations": "recomputedOnly"})])
    plain_observed, plain_expected = mutate(plain, expected_plain, "observations_sha256", "both")
    builder.add("observations-side/plain-only", request_text(plain_observed, plain_expected),
                {"certificate", "observations-side"}, [check_digests({"observations": "certificateOnly"})])


COMPLETENESS_SCENARIOS = ("pure", "presence", "variant", "http")
EXECUTION_MANIFEST = ROOT / "verification" / "execution" / "rust_driver" / "Cargo.toml"


def return_nodes(value):
    if isinstance(value, dict):
        if value.get("tag") == "Return":
            yield value
        for item in value.values():
            yield from return_nodes(item)
    elif isinstance(value, list):
        for item in value:
            yield from return_nodes(item)


def returned(plan) -> tuple[list[list[str]], list[str]]:
    successes, embeddings = [], []
    for node in return_nodes(plan):
        value = node["value"]
        if value.get("tag") == "Success":
            successes.append([port for port, _ in value["value"]])
        else:
            embeddings.append(value["fields"]["embedding"])
    return successes, embeddings


def completeness_failures(composition) -> list[str]:
    goal = composition["problem"]["goal"]
    successes, embeddings = returned(composition["derivation"]["plan"])
    outputs = sorted(output["id"] for output in goal["outputs"])
    failures = []
    if not successes:
        failures.append("no Return node returns the declared outputs")
    failures.extend(f"a Return node returns {sorted(ports)} for the declared outputs {outputs}"
                    for ports in successes if sorted(ports) != outputs)
    failures.extend(f"the declared failure embedding {failure['id']} has no Return node"
                    for failure in goal["failures"] if failure["id"] not in embeddings)
    failures.extend(f"a Return node returns the undeclared embedding {embedding}"
                    for embedding in embeddings if embedding not in {failure["id"] for failure in goal["failures"]})
    return failures


def completeness_mutations(composition):
    def goal_change(change):
        def apply(value):
            change(value["problem"]["goal"])
            change(value["derivation"]["witness"]["input_snapshot"]["goal"])
        return apply

    def first_success(value):
        return next(node["value"] for node in return_nodes(value["derivation"]["plan"]) if node["value"].get("tag") == "Success")

    def first_failure(value):
        return next(node["value"] for node in return_nodes(value["derivation"]["plan"]) if node["value"].get("tag") != "Success")

    yield "return-port-removed", lambda value: first_success(value)["value"].pop()
    yield "return-port-added", lambda value: first_success(value)["value"].append(
        ["undeclared-port", copy.deepcopy(first_success(value)["value"][0][1])])
    yield "goal-output-removed", goal_change(lambda goal: goal["outputs"].pop())
    yield "goal-output-added", goal_change(lambda goal: goal["outputs"].append({**copy.deepcopy(goal["outputs"][0]), "id": "undeclared-port"}))
    if composition["problem"]["goal"]["failures"]:
        yield "return-embedding-renamed", lambda value: first_failure(value)["fields"].__setitem__("embedding", "undeclared-embedding")
        yield "goal-failure-removed", goal_change(lambda goal: goal["failures"].pop())
        yield "goal-failure-added", goal_change(lambda goal: goal["failures"].append(
            {**copy.deepcopy(goal["failures"][0]), "id": "undeclared-embedding"}))


def check_rejected():
    def check(out, results):
        return None if out.get("result") == "failed" else f"expected a rejection, got {short(out)}"
    return check


def check_incomplete_plan(goal):
    check = check_conditions({**{name: MATCHED for name in CONDITIONS}, "observations": MISMATCHED}) \
        if goal["outputs"] else check_rejected()
    check.propagation = check_rejected()
    return check


def add_completeness_cases(builder: Builder) -> None:
    proc = subprocess.run([which("cargo"), "run", "--locked", "--quiet", "--manifest-path", str(EXECUTION_MANIFEST), "--bin", "generate"],
                          input=compact({"scenarios": list(COMPLETENESS_SCENARIOS)}), capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(f"the execution scenarios failed: {proc.stderr[-400:]}")
    for name, text in json.loads(proc.stdout).items():
        exchange = json.loads(text)
        problems = completeness_failures(exchange["composition"])
        if problems:
            raise SystemExit(f"the {name} plan is incomplete: {problems}")
        builder.add(f"completeness/{name}-accepted", request_text(exchange, exchange["basis"]), {"completeness"}, [check_accepted()])
        for label, mutate in completeness_mutations(exchange["composition"]):
            changed = copy.deepcopy(exchange)
            mutate(changed["composition"])
            if not completeness_failures(changed["composition"]):
                raise SystemExit(f"the {name} mutation {label} leaves the plan complete")
            changed["basis"]["problem_sha256"] = composition_digest(changed["composition"])
            changed["basis"]["observations_sha256"] = exhaustive.observations_digest(changed["composition"])
            builder.add(f"completeness/{name}-{label}", request_text(changed, changed["basis"]), {"completeness"},
                        [check_incomplete_plan(changed["composition"]["problem"]["goal"])])


def build_cases(plain_text: str, composition_text: str, builder: Builder) -> None:
    plain = json.loads(plain_text)
    composition = json.loads(composition_text)
    expected_plain = copy.deepcopy(plain["basis"])
    expected_composition = copy.deepcopy(composition["basis"])

    builder.add("accept/plain", request_text(plain_text, expected_plain), {"accept"}, [check_accepted()])
    builder.add("accept/composition", request_text(composition_text, expected_composition),
                {"accept"}, [check_accepted()])

    add_text_entry_cases(builder, plain_text, expected_plain)

    for kind, exchange, expected in (("plain", plain, expected_plain),
                                     ("composition", composition, expected_composition)):
        for field_name in BASIS_FIELDS:
            for mode in ("expected", "declared", "both"):
                changed_exchange, changed_expected = mutate(exchange, expected, field_name, mode)
                labels = {"certificate", "basis-mutation"}
                checks = [check_conditions(expected_conditions(field_name, mode))]
                if field_name == "graph_sha256" and mode == "declared":
                    labels.add("projection-names")
                    checks.append(check_digests({"graph": "different"}))
                builder.add(f"basis-mutation/{kind}-{field_name}-{mode}",
                            request_text(changed_exchange, changed_expected), labels, checks)

    problem_exchange, problem_expected = mutate(plain, expected_plain, "problem_sha256", "both")
    builder.add("problem-side/plain-only", request_text(problem_exchange, problem_expected),
                {"certificate", "problem-side"}, [check_digests({"problem": "certificateOnly"})])
    problem_null_exchange = copy.deepcopy(composition)
    problem_null_exchange["basis"]["problem_sha256"] = None
    problem_null_expected = copy.deepcopy(expected_composition)
    problem_null_expected["problem_sha256"] = None
    builder.add("problem-side/composition-only", request_text(problem_null_exchange, problem_null_expected),
                {"certificate", "problem-side"}, [check_digests({"problem": "recomputedOnly"})])
    add_observation_cases(builder, plain, composition, expected_plain, expected_composition)
    add_completeness_cases(builder)

    for kind, exchange, expected in (("plain", plain, expected_plain),
                                     ("composition", composition, expected_composition)):
        both_changed = copy.deepcopy(exchange)
        both_changed["basis"]["library_identity"] = ALTERNATIVE["library_identity"]
        both_changed["basis"]["graph_sha256"] = ALTERNATIVE["graph_sha256"]
        source_digest = {name: MATCHED for name in CONDITIONS}
        source_digest.update(source=MISMATCHED, digest=MISMATCHED, coordinate=UNCHECKED_BY_SOURCE,
                             observations=UNCHECKED_BY_SOURCE, residual=UNCHECKED_BY_SOURCE)
        builder.add(f"source-digest/{kind}", request_text(both_changed, expected),
                    {"certificate", "source-digest"}, [check_conditions(source_digest)])

    two_roots = copy.deepcopy(plain)
    two_roots["schema"] = "ncoh-checked-generation@9"
    two_roots["basis"]["library_identity"] = ALTERNATIVE["library_identity"]
    builder.add("two-roots/schema-and-source", request_text(two_roots, expected_plain),
                {"non-certificate", "two-roots"}, [check_kind("schema")])

    schema_only = copy.deepcopy(plain)
    schema_only["schema"] = "ncoh-checked-generation@9"
    builder.add("non-certificate/schema", request_text(schema_only, expected_plain),
                {"non-certificate"}, [check_kind("schema")])

    empty = copy.deepcopy(plain)
    empty["entrypoints"] = []
    builder.add("non-certificate/entrypoints-empty", request_text(empty, expected_plain),
                {"non-certificate"}, [check_kind("entrypoints_empty")])

    identity_empty = copy.deepcopy(plain)
    identity_empty["entrypoints"][0]["identity"] = ""
    builder.add("non-certificate/entrypoint-identity-empty", request_text(identity_empty, expected_plain),
                {"non-certificate"}, [check_kind("entrypoint_identity_empty")])

    duplicate = copy.deepcopy(plain)
    duplicate["entrypoints"] = [plain["entrypoints"][0], plain["entrypoints"][0]]
    builder.add("non-certificate/entrypoint-duplicate", request_text(duplicate, expected_plain),
                {"non-certificate"}, [check_kind("entrypoint_duplicate")])

    unresolved = copy.deepcopy(plain)
    unresolved["entrypoints"][0]["definition"] = "missing-definition"
    builder.add("non-certificate/entrypoint-unresolved", request_text(unresolved, expected_plain),
                {"non-certificate"}, [check_kind("entrypoint_unresolved")])

    declaration = copy.deepcopy(plain)
    declaration["signatures"]["revision"] = ""
    builder.add("non-certificate/declaration-revision-empty", request_text(declaration, expected_plain),
                {"non-certificate"})

    no_derivation = copy.deepcopy(composition)
    no_derivation["composition"].pop("derivation", None)
    builder.add("non-certificate/composition-derivation-missing",
                request_text(no_derivation, expected_composition), {"non-certificate"})

    closure_example = json.loads((ENTRY_DIR / "examples" / "rejected-closure-used-site.request.json").read_text(
        encoding="utf-8"))
    builder.add("non-certificate/composition-closure-used-site", compact(closure_example),
                {"non-certificate"}, [check_derivation_verified(check_kind("composition"))])

    plain_document = exhaustive.expected_document(expected_plain, None)
    builder.add("non-certificate/exchange-json", compact({"exchange": "{bad", "expected_basis": plain_document}),
                {"non-certificate"}, [check_kind("decode")])
    builder.add("non-certificate/request-exchange-missing", compact({"expected_basis": plain_document}),
                {"non-certificate"}, [check_kind("request")])

    reversed_entries = copy.deepcopy(plain)
    reversed_entries["entrypoints"] = list(reversed(plain["entrypoints"]))
    builder.add("order-independence/entrypoints-reversed", request_text(reversed_entries, expected_plain),
                {"order-independence"}, [check_same_as("accept/plain")])

    declaration_duplicate = copy.deepcopy(plain)
    declaration_duplicate["signatures"]["revision"] = ""
    declaration_duplicate["entrypoints"] = [plain["entrypoints"][0], plain["entrypoints"][0]]
    builder.add("check-order/declaration-and-duplicate", request_text(declaration_duplicate, expected_plain),
                {"check-order"}, [check_kind("entrypoint_duplicate")])

    digest_and_unresolved = copy.deepcopy(plain)
    digest_and_unresolved["basis"]["graph_sha256"] = ALTERNATIVE["graph_sha256"]
    digest_and_unresolved["entrypoints"].append({"identity": "unresolved-entry", "definition": "missing-definition"})
    builder.add("check-order/digest-and-unresolved", request_text(digest_and_unresolved, expected_plain),
                {"check-order"}, [check_kind("entrypoint_unresolved")])

    request_cases = [
        ("non-certificate/request-json", "{not json"),
        ("non-certificate/request-not-object", "[]"),
        ("non-certificate/request-exchange-not-string", compact({"exchange": 1, "expected_basis": plain_document})),
        ("non-certificate/request-expected-basis-missing", compact({"exchange": plain_text})),
        ("non-certificate/expected-basis-not-object", compact({"exchange": plain_text, "expected_basis": "x"})),
        ("non-certificate/expected-basis-unknown-field",
         compact({"exchange": plain_text, "expected_basis": dict(plain_document, extra=1)})),
        ("non-certificate/expected-basis-basis-unknown-field",
         compact({"exchange": plain_text, "expected_basis": exhaustive.expected_document(dict(expected_plain, extra=1), None)})),
        ("non-certificate/expected-basis-missing-field",
         compact({"exchange": plain_text,
                  "expected_basis": exhaustive.expected_document(
                      {key: value for key, value in expected_plain.items() if key != "problem_sha256"}, None)})),
        ("non-certificate/expected-basis-observations-missing",
         compact({"exchange": plain_text, "expected_basis": {"basis": expected_plain}})),
        ("non-certificate/expected-basis-observations-unknown-field",
         compact({"exchange": composition_text, "expected_basis": {"basis": expected_composition, "observations": dict(
             exhaustive.goal_observations(composition["composition"]), extra=1)}})),
    ]
    for name, text in request_cases:
        builder.add(name, text, {"non-certificate"})
    builder.add("accept/request-extra-field",
                compact({"exchange": plain_text, "expected_basis": plain_document, "extra": 1}),
                {"accept"}, [check_accepted()])

    builder.add("non-certificate/exchange-unknown-field", request_text(dict(plain, extra=1), expected_plain),
                {"non-certificate"})
    builder.add("non-certificate/exchange-schema-not-string", request_text(dict(plain, schema=1), expected_plain),
                {"non-certificate"})
    unknown_tag = copy.deepcopy(plain)
    unknown_tag["signatures"]["definitions"][0]["shape"]["tag"] = "NoSuchTag"
    builder.add("non-certificate/exchange-unknown-tag", request_text(unknown_tag, expected_plain), {"non-certificate"})

    library_schema = copy.deepcopy(plain)
    library_schema["signatures"]["schema"] = "ncoh-type-signatures@9"
    builder.add("non-certificate/library-schema-outside-version", request_text(library_schema, expected_plain),
                {"non-certificate"}, [check_reason("declaration", "lb01")])

    expected_identity = copy.deepcopy(expected_plain)
    expected_identity["library_identity"] = ""
    builder.add("basis-value/expected-library-identity-empty", request_text(plain_text, expected_identity),
                {"basis-value"})
    declared_identity = copy.deepcopy(plain)
    declared_identity["basis"]["library_identity"] = ""
    builder.add("basis-value/declared-library-identity-empty", request_text(declared_identity, expected_plain),
                {"basis-value"})
    expected_profile = copy.deepcopy(expected_plain)
    expected_profile["profile"]["identity"] = ""
    builder.add("basis-value/expected-profile-identity-empty", request_text(plain_text, expected_profile),
                {"basis-value"})
    declared_profile = copy.deepcopy(plain)
    declared_profile["basis"]["profile"]["identity"] = ""
    builder.add("basis-value/declared-profile-identity-empty", request_text(declared_profile, expected_plain),
                {"basis-value"})
    expected_digest = copy.deepcopy(expected_plain)
    expected_digest["graph_sha256"] = "not-a-digest"
    builder.add("basis-value/expected-graph-not-digest", request_text(plain_text, expected_digest),
                {"basis-value"})
    for label, value in (("uppercase", "A" * 64), ("non-hex", "g" * 64)):
        declared_digest = copy.deepcopy(plain)
        declared_digest["basis"]["graph_sha256"] = value
        builder.add(f"basis-value/declared-graph-{label}", request_text(declared_digest, expected_plain),
                    {"basis-value"})
    problem_exchange = copy.deepcopy(composition)
    problem_exchange["basis"]["problem_sha256"] = "xyz"
    problem_expected = copy.deepcopy(expected_composition)
    problem_expected["problem_sha256"] = "xyz"
    builder.add("basis-value/problem-not-digest", request_text(problem_exchange, problem_expected),
                {"basis-value"})
    problem_number = copy.deepcopy(plain)
    problem_number["basis"]["problem_sha256"] = 1
    builder.add("basis-value/declared-problem-not-string", request_text(problem_number, expected_plain),
                {"basis-value"})

    def composition_case(name, changed, checks, labels=("composition-wire",)):
        exchange_obj = copy.deepcopy(composition)
        exchange_obj["composition"] = changed
        digest = composition_digest(changed)
        exchange_obj["basis"]["problem_sha256"] = digest
        exchange_obj["basis"]["observations_sha256"] = exhaustive.observations_digest(changed)
        expected_obj = copy.deepcopy(expected_composition)
        expected_obj["problem_sha256"] = digest
        expected_obj["observations_sha256"] = exhaustive.observations_digest(changed)
        builder.add(name, request_text(exchange_obj, expected_obj), set(labels), checks)

    base_composition = copy.deepcopy(composition["composition"])
    if composition_digest(base_composition) != composition["basis"]["problem_sha256"]:
        raise RuntimeError("the composition digest method does not match the generator")
    problem_extra = copy.deepcopy(base_composition)
    problem_extra["problem"]["extra"] = 1
    composition_case("composition-wire/problem-unknown-field", problem_extra,
                     [check_reason("composition", "unknownField")])
    derivation_tag = copy.deepcopy(base_composition)
    derivation_tag["derivation"]["plan"]["root"]["node"]["tag"] = "NoSuchTag"
    composition_case("composition-wire/derivation-unknown-tag", derivation_tag,
                     [check_reason("composition", "unknownTag")])
    problem_missing = copy.deepcopy(base_composition)
    del problem_missing["problem"]["bounds"]
    composition_case("composition-wire/problem-missing-field", problem_missing,
                     [check_reason("composition", "syntax")])
    composition_case("composition-wire/composition-not-object", "x",
                     [check_reason("composition", "syntax")])

    composition_extra = copy.deepcopy(base_composition)
    composition_extra["extra"] = 1
    composition_case("decode-stage/composition-unknown-field", composition_extra,
                     [check_reason("composition", "unknownField")], labels=("decode-stage",))

    add_mutation_cases(builder, plain, expected_plain)
    add_second_stage_cases(builder, plain, composition, expected_plain, expected_composition)
    add_json_stage_cases(builder, plain, composition, expected_plain, expected_composition)

    for case in builder.cases:
        if case.labels & {"certificate", "non-certificate"} or any(
                hasattr(check, "propagation") for check in case.checks):
            case.labels.add("propagation")



LOWER = "abcdefghijklmnopqrstuvwxyz"
DIGITS = "0123456789"
ZERO_DIGEST = "0" * 64


def unit_tag(name):
    return {"tag": name}


def tuple_tag(name, value):
    return {"tag": name, "value": value}


def record_tag(name, **fields):
    return {"tag": name, "fields": fields}


def profile_ref():
    return {"identity": "ncoh-value-semantics", "revision": "1", "content_digest": ZERO_DIGEST}


def source_identity():
    return {"repository": "adapter", "revision": "1", "path": "contract", "content_digest": ZERO_DIGEST}


def origin(source=None):
    return {"source": source or source_identity(), "locator": ["operation"]}


def string_spec(**given):
    spec = {"format": None, "lengths": [], "wrapper": None, "const_value": None, "enum_values": None,
            "examples": [], "default_value": None}
    spec.update(given)
    return spec


def integer_spec(**given):
    spec = {"domain": None, "minimum": None, "maximum": None, "const_value": None, "enum_values": None,
            "default_value": None}
    spec.update(given)
    return spec


def leaf_string(**given):
    return tuple_tag("String", string_spec(**given))


def leaf_integer(**given):
    return tuple_tag("Integer", integer_spec(**given))


def named(name):
    return tuple_tag("Named", name)


def inline(rule):
    return tuple_tag("Inline", rule)


def length_bound(minimum=None, maximum=None, unit="Utf8Bytes"):
    return {"unit": unit_tag(unit), "minimum": minimum, "maximum": maximum}


def rule_timestamp(minimum="1970", maximum="2100"):
    return tuple_tag("Timestamp", {"allow_second_60": False, "minimum_year": minimum, "maximum_year": maximum,
                                   "rejectUtcYearOutsideRange": False})


def rule_dfa(state_count="2", initial="0", accepting=("1",), transitions=(("0", "97", "122", "1"),)):
    return tuple_tag("AsciiDfa", {
        "state_count": state_count, "initial_state": initial, "accepting_states": list(accepting),
        "transitions": [{"from_state": f, "first": a, "last": b, "to_state": t} for f, a, b, t in transitions]})


def rule_identifier(first=LOWER, rest=LOWER + DIGITS, exact=None, minimum="1", maximum=None, forbidden=()):
    return record_tag("Identifier", first_alphabet=first, rest_alphabet=rest, exact_length=exact,
                      min_length=minimum, max_length=maximum, forbidden=list(forbidden))


def rule_labels(separator=".", inner=None):
    return record_tag("Labels", separator=separator, min_count="1", max_count=None, total_max=None,
                      rule=inner or unit_tag("Text"))


def rule_sequence(*rules):
    return tuple_tag("Sequence", list(rules))


def rule_optional(rule):
    return tuple_tag("Optional", rule)


def rule_choice(*rules):
    return tuple_tag("Choice", list(rules))


def rule_not(rule):
    return tuple_tag("Not", rule)


def rule_bounded(rule, maximum="10"):
    return record_tag("Bounded", unit=unit_tag("Utf8Bytes"), maximum=maximum, rule=rule)


def rule_nested(rule, depth):
    for _ in range(depth):
        rule = rule_optional(rule)
    return rule


def binding(name, rule):
    return {"name": name, "reference": profile_ref(), "rule": rule}


def slot(type_id, required=True, nullable=False):
    return {"type_id": type_id, "required": required, "nullable": nullable}


def node(node_id, shape):
    return {"id": node_id, "shape": shape}


def string_node(node_id, **spec):
    return node(node_id, tuple_tag("String", string_spec(**spec)))


def integer_node(node_id, **spec):
    return node(node_id, tuple_tag("Integer", integer_spec(**spec)))


def product_node(node_id, fields, extras=None):
    return node(node_id, tuple_tag("Product", {
        "fields": [{"wire_name": name, "slot": slot(type_id)} for name, type_id in fields],
        "extras": extras or unit_tag("Reject")}))


def extras_allow(key_format, type_id="truth"):
    return record_tag("Allow", key_format=key_format, value={"type_id": type_id, "nullable": False})


def extras_node(node_id, key_format, type_id="truth"):
    return node(node_id, tuple_tag("Product", {"fields": [], "extras": extras_allow(key_format, type_id)}))


def branch(target, wire_tag, selector):
    return {"target": target, "wire_tag": wire_tag, "selector": selector}


def union_node(node_id, branches):
    return node(node_id, tuple_tag("TaggedUnion", {"branches": list(branches)}))


def sealed_node(node_id, form_tag, refinements=()):
    return node(node_id, record_tag("Sealed", tag=form_tag,
                                    refinements=[{"key": key, "leaf": leaf} for key, leaf in refinements]))


def array_node(node_id, item="truth", minimum=None, maximum=None):
    return node(node_id, tuple_tag("Array", {"item": {"type_id": item, "nullable": False},
                                             "min_length": minimum, "max_length": maximum}))


def bytes_node(node_id, minimum=None, maximum=None):
    return node(node_id, tuple_tag("Bytes", {"minimum": minimum, "maximum": maximum}))


def decimal_bound(mantissa, scale, exclusive=False):
    return {"mantissa": mantissa, "scale": scale, "exclusive": exclusive}


def decimal_node(node_id, minimum=None, maximum=None):
    return node(node_id, tuple_tag("Decimal", {"minimum": minimum, "maximum": maximum}))


def alias_node(node_id, target):
    return node(node_id, record_tag("Alias", target=target))


INTERNAL_TAG = unit_tag("InternalTag")
OTHERWISE = unit_tag("Otherwise")
ABSENT = unit_tag("Absent")


def kind_selector(kind):
    return tuple_tag("Kind", unit_tag(kind))


def member_shape(*tests):
    return tuple_tag("MemberShape", [{"key": key, "test": test} for key, test in tests])


def format_test(name):
    return tuple_tag("Format", name)


def target_group(identifier):
    return tuple_tag("Group", identifier)


def target_definition(identifier):
    return tuple_tag("Definition", identifier)


def target_type(identifier):
    return tuple_tag("Type", identifier)


def target_outcome(definition, outcome):
    return record_tag("Outcome", definition=definition, outcome=outcome)


def provenance_binding(target, *origins):
    return {"target": target, "origins": list(origins)}


def annotation(target):
    return {"target": target, "key": "note", "value": tuple_tag("String", "text")}


def resource(identifier="token", token_type="truth"):
    return {"id": identifier, "token_type": token_type, "revision": "1", "quantity": "1", "provenance": "produced"}


def grapheme_rules(**given):
    rules = {"reference": profile_ref(),
             "component": {"unicode_version": "16.0.0", "uax29_revision": "45",
                           "cluster_profile": "C1-1-default-extended-grapheme-cluster-no-tailoring"},
             "table_sha256": ZERO_DIGEST, "sources": [], "properties": [], "extended_pictographic": [],
             "indic_conjunct": []}
    rules.update(given)
    return rules


def bytes_policy(**given):
    policy = {"reference": profile_ref(), "padding_optional": False, "alphabet": unit_tag("Standard"),
              "strict_pad_bits": True, "wrapper": None}
    policy.update(given)
    return policy


def rich_library(plain_library):
    library = copy.deepcopy(plain_library)
    if library["sources"] != [source_identity()] or library["profile"]["reference"] != profile_ref():
        raise RuntimeError("the generated library does not carry the source and profile that the corpus assumes")
    profile = library["profile"]
    profile["format_bindings"] = [binding("tagname", rule_identifier()), binding("anytext", unit_tag("Text"))]
    profile["wrappers"] = [
        {"name": "textwrap", "key": "wrapkey", "payload": tuple_tag("Text", "anytext")},
        {"name": "bytewrap", "key": "bytekey", "payload": unit_tag("Bytes")},
    ]
    profile["tag"] = {"key": "kind", "format": "tagname", "sealed": [{
        "tag": "refd",
        "fields": [{"key": "target", "required": True, "leaf": leaf_string()},
                   {"key": "count", "required": True, "leaf": leaf_integer(domain="integer")}],
        "extras": unit_tag("Reject")}]}
    library["nodes"] += [
        string_node("tagstr", format=named("tagname")),
        product_node("recA", [("kind", "tagstr")]),
        sealed_node("sealedref", "refd", [("target", leaf_string()), ("count", leaf_integer(domain="integer"))]),
        union_node("union", [branch("recA", "reca", INTERNAL_TAG), branch("sealedref", "refd", INTERNAL_TAG)]),
    ]
    return library


def operation_of(library):
    return library["definitions"][1]["shape"]["value"]


def replace_source(library, new_source):
    old = source_identity()

    def walk(value):
        if isinstance(value, dict):
            if value == old:
                return copy.deepcopy(new_source)
            return {key: walk(item) for key, item in value.items()}
        if isinstance(value, list):
            return [walk(item) for item in value]
        return value

    rewritten = walk(library)
    library.clear()
    library.update(rewritten)


def appending(*nodes):
    def change(library):
        library["nodes"].extend(copy.deepcopy(list(nodes)))
    return change


def prepending(*nodes):
    def change(library):
        library["nodes"][0:0] = copy.deepcopy(list(nodes))
    return change


def on_profile(change):
    def apply(library):
        change(library["profile"])
    return apply


def together(*changes):
    def apply(library):
        for change in changes:
            change(library)
    return apply


def set_path(root, path, value):
    target = root
    for step in path[:-1]:
        target = target[step]
    target[path[-1]] = copy.deepcopy(value)


def setting(path, value):
    def change(library):
        set_path(library, path, value)
    return change


def bad_format_rules():
    return [
        ("timestamp-year-order", rule_timestamp("2100", "1970")),
        ("timestamp-year-over-9999", rule_timestamp("1970", "10000")),
        ("dfa-state-count-zero", rule_dfa("0", "0", (), ())),
        ("dfa-initial-out-of-range", rule_dfa(initial="2")),
        ("dfa-accepting-out-of-range", rule_dfa(accepting=("2",))),
        ("dfa-from-state-out-of-range", rule_dfa(transitions=(("2", "97", "122", "1"),))),
        ("dfa-to-state-out-of-range", rule_dfa(transitions=(("0", "97", "122", "2"),))),
        ("dfa-range-reversed", rule_dfa(transitions=(("0", "122", "97", "1"),))),
        ("dfa-range-beyond-ascii", rule_dfa(transitions=(("0", "97", "128", "1"),))),
        ("dfa-overlap-same-state", rule_dfa(transitions=(("0", "97", "100", "1"), ("0", "99", "102", "1")))),
        ("identifier-first-non-ascii", rule_identifier(first="\u00e9")),
        ("identifier-rest-non-ascii", rule_identifier(rest="ab\u00e9")),
        ("identifier-first-empty", rule_identifier(first="")),
        ("identifier-rest-empty", rule_identifier(rest="")),
        ("identifier-maximum-below-minimum", rule_identifier(minimum="5", maximum="3")),
        ("identifier-exact-below-minimum", rule_identifier(exact="2", minimum="3")),
        ("identifier-exact-above-maximum", rule_identifier(exact="9", maximum="5")),
        ("labels-separator-empty", rule_labels(separator="")),
        ("sequence-nested-timestamp", rule_sequence(unit_tag("Text"), rule_timestamp("2100", "1970"))),
        ("optional-nested-dfa", rule_optional(rule_dfa(initial="2"))),
        ("choice-nested-identifier", rule_choice(unit_tag("Text"), rule_identifier(first="\u00e9"))),
        ("not-nested-timestamp", rule_not(rule_timestamp("2100", "1970"))),
        ("bounded-nested-labels", rule_bounded(rule_labels(separator=""))),
        ("labels-nested-timestamp", rule_labels(".", rule_timestamp("2100", "1970"))),
        ("deep-nested-timestamp", rule_nested(rule_timestamp("2100", "1970"), 30)),
    ]


LEAF_FORMAT_RULES = ("timestamp-year-order", "dfa-to-state-out-of-range", "dfa-overlap-same-state",
                     "identifier-first-non-ascii", "identifier-rest-non-ascii", "labels-separator-empty",
                     "sequence-nested-timestamp", "deep-nested-timestamp")


def add_mutation_cases(builder, plain, expected_plain) -> None:
    base_library = rich_library(plain["signatures"])

    def exchange_with(change):
        exchange = copy.deepcopy(plain)
        library = copy.deepcopy(base_library)
        change(library)
        exchange["signatures"] = library
        return exchange

    def declare(label, name, change, reason, expected=None):
        builder.add(f"{label}/{name}", request_text(exchange_with(change), expected or expected_plain), {label},
                    [check_reason("declaration", reason)])

    def declare_kind(label, name, change, kind, exchange_change=None):
        exchange = exchange_with(change)
        if exchange_change is not None:
            exchange_change(exchange)
        builder.add(f"{label}/{name}", request_text(exchange, expected_plain), {label}, [check_kind(kind)])

    declare_kind("library-predicate", "valid-rich-library", lambda library: None, "certificate")
    declare_library_declaration(declare, declare_kind)
    declare_library_predicates(declare)
    declare_profile_predicates(declare, declare_kind)
    declare_predicate_order(declare, declare_kind, expected_plain)
    declare_decode_stage(builder, plain, expected_plain)
    declare_library_shape(declare_kind)


def declare_library_declaration(declare, declare_kind) -> None:
    label = "library-predicate"

    def lb01(name, change):
        declare(label, f"lb01-{name}", change, "lb01")

    def profile_digest(digest):
        return setting(["profile", "reference", "content_digest"], digest)

    lb01("profile-digest-short", profile_digest("abc"))
    lb01("profile-digest-uppercase", profile_digest("A" * 64))
    lb01("profile-digest-too-long", profile_digest("0" * 65))
    lb01("profile-digest-non-hex", profile_digest("g" * 64))
    for name, digest in (("short", "abc"), ("uppercase", "A" * 64), ("non-hex", "g" * 64)):
        lb01(f"source-digest-{name}", lambda library, digest=digest: replace_source(
            library, dict(source_identity(), content_digest=digest)))
    lb01("source-duplicate", lambda library: library["sources"].append(source_identity()))
    lb01("identity-empty", setting(["identity"], ""))
    lb01("revision-empty", setting(["revision"], ""))
    lb01("node-id-duplicate", lambda library: library["nodes"].append(copy.deepcopy(library["nodes"][0])))
    lb01("node-id-empty", appending(string_node("")))
    lb01("definition-id-duplicate",
         lambda library: library["definitions"].append(copy.deepcopy(library["definitions"][0])))
    lb01("definition-id-empty", lambda library: library["definitions"].append(
        dict(copy.deepcopy(library["definitions"][0]), id="")))
    lb01("group-id-duplicate", lambda library: library["groups"].append(copy.deepcopy(library["groups"][0])))
    lb01("group-id-empty", lambda library: library["groups"].append({"id": "", "members": []}))
    lb01("group-member-undefined", lambda library: library["groups"][0]["members"].append("no-such-definition"))
    lb01("operation-input-id-duplicate", lambda library: operation_of(library)["inputs"].append(
        copy.deepcopy(operation_of(library)["inputs"][0])))
    lb01("operation-input-id-empty", lambda library: operation_of(library)["inputs"].append(
        {"id": "", "contract": slot("truth")}))
    lb01("outcome-id-duplicate", lambda library: operation_of(library)["outcomes"].append(
        copy.deepcopy(operation_of(library)["outcomes"][0])))
    lb01("outcome-id-empty", lambda library: operation_of(library)["outcomes"].append(
        dict(copy.deepcopy(operation_of(library)["outcomes"][0]), id="")))
    lb01("outcomes-empty", lambda library: operation_of(library).update(outcomes=[]))
    lb01("outcome-port-id-duplicate", lambda library: operation_of(library)["outcomes"][0]["value_ports"].append(
        copy.deepcopy(operation_of(library)["outcomes"][0]["value_ports"][0])))
    lb01("outcome-port-id-empty", lambda library: operation_of(library)["outcomes"][0]["value_ports"].append(
        {"id": "", "contract": slot("truth")}))
    lb01("outcome-resource-id-duplicate", lambda library: operation_of(library)["outcomes"][0].update(
        produced_resources=[resource(), resource()]))
    lb01("outcome-resource-id-empty", lambda library: operation_of(library)["outcomes"][0].update(
        produced_resources=[resource("")]))
    lb01("outcome-value-contract-origin-unknown", setting(
        ["definitions", 1, "shape", "value", "outcomes", 0, "cause", "fields", "origin", "source", "repository"],
        "other"))
    lb01("outcome-external-origin-unknown", setting(
        ["definitions", 1, "shape", "value", "outcomes", 1, "cause", "fields", "specification", "source", "path"],
        "other"))
    lb01("outcome-external-without-ports", setting(
        ["definitions", 1, "shape", "value", "outcomes", 1, "value_ports"], []))
    lb01("outcome-external-with-success-form", setting(
        ["definitions", 1, "shape", "value", "outcomes", 1, "form"], unit_tag("Success")))
    unknown = dict(source_identity(), repository="elsewhere")
    lb01("provenance-group-undefined",
         lambda library: library["provenance"].append(provenance_binding(target_group("none"), origin())))
    lb01("provenance-definition-undefined",
         lambda library: library["provenance"].append(provenance_binding(target_definition("none"), origin())))
    lb01("provenance-type-undefined",
         lambda library: library["provenance"].append(provenance_binding(target_type("none"), origin())))
    lb01("provenance-outcome-undefined", lambda library: library["provenance"].append(
        provenance_binding(target_outcome("operation", "none"), origin())))
    lb01("provenance-outcome-of-value-definition", lambda library: library["provenance"].append(
        provenance_binding(target_outcome("value", "success"), origin())))
    lb01("provenance-origin-unknown", lambda library: library["provenance"].append(
        provenance_binding(unit_tag("Library"), origin(unknown))))
    lb01("provenance-second-origin-unknown", lambda library: library["provenance"].append(
        provenance_binding(unit_tag("Library"), origin(), origin(unknown))))
    lb01("annotation-group-undefined",
         lambda library: library["annotations"].append(annotation(target_group("none"))))
    lb01("annotation-definition-undefined",
         lambda library: library["annotations"].append(annotation(target_definition("none"))))
    lb01("annotation-type-undefined",
         lambda library: library["annotations"].append(annotation(target_type("none"))))
    lb01("annotation-outcome-undefined",
         lambda library: library["annotations"].append(annotation(target_outcome("operation", "none"))))
    lb01("annotation-outcome-of-value-definition",
         lambda library: library["annotations"].append(annotation(target_outcome("value", "success"))))
    lb01("node-alias-target-undefined", appending(alias_node("dangling", "none")))
    lb01("node-product-field-type-undefined", appending(product_node("dangling", [("a", "none")])))
    lb01("node-product-extras-type-undefined", appending(extras_node("dangling", None, "none")))
    lb01("node-array-item-undefined", appending(array_node("dangling", "none")))
    lb01("node-union-target-undefined",
         appending(union_node("dangling", [branch("none", "x", kind_selector("String"))])))
    lb01("definition-value-type-undefined", setting(["definitions", 0, "shape", "value"], "none"))
    lb01("definition-message-type-undefined", setting(["definitions", 0, "shape"], tuple_tag("Message", "none")))
    lb01("operation-input-type-undefined",
         setting(["definitions", 1, "shape", "value", "inputs", 0, "contract", "type_id"], "none"))
    lb01("outcome-port-type-undefined",
         setting(["definitions", 1, "shape", "value", "outcomes", 0, "value_ports", 0, "contract", "type_id"],
                 "none"))
    lb01("outcome-resource-token-type-undefined", lambda library: operation_of(library)["outcomes"][0].update(
        produced_resources=[resource("token", "none")]))

    def valid_targets(library):
        library["provenance"].extend([
            provenance_binding(unit_tag("Library"), origin()),
            provenance_binding(target_group("document"), origin()),
            provenance_binding(target_definition("operation"), origin()),
            provenance_binding(target_type("truth"), origin()),
            provenance_binding(target_outcome("operation", "success"), origin())])
        library["annotations"].extend([
            annotation(unit_tag("Library")), annotation(target_group("document")),
            annotation(target_definition("value")), annotation(target_type("unit")),
            annotation(target_outcome("operation", "refused"))])

    declare_kind(label, "provenance-and-annotation-valid-targets", valid_targets, "certificate")


def declare_library_predicates(declare) -> None:
    label = "library-predicate"

    def case(reason, name, change):
        declare(label, f"{reason}-{name}", change, reason)

    case("lb02", "duplicate-wire-name", appending(product_node("bad", [("a", "truth"), ("a", "truth")])))
    case("lb02", "empty-wire-name", appending(product_node("bad", [("", "truth")])))
    case("lb03", "field-named-as-text-wrapper-key", appending(product_node("bad", [("wrapkey", "truth")])))
    case("lb03", "field-named-as-bytes-wrapper-key", appending(product_node("bad", [("bytekey", "truth")])))
    case("lb04", "duplicate-wire-tag", appending(union_node("bad", [
        branch("truth", "same", kind_selector("Boolean")), branch("unit", "same", kind_selector("Null"))])))
    case("lb05", "otherwise-first", appending(union_node("bad", [
        branch("truth", "rest", OTHERWISE), branch("unit", "last", kind_selector("Null"))])))
    case("lb05", "otherwise-twice", appending(union_node("bad", [
        branch("truth", "rest", OTHERWISE), branch("unit", "last", OTHERWISE)])))
    case("lb06", "empty-wire-tag", appending(union_node("bad", [branch("truth", "", kind_selector("Boolean"))])))
    case("lb06", "empty-member-test-key", appending(union_node("bad", [
        branch("truth", "named", member_shape(("", ABSENT)))])))
    case("lb07", "internal-tag-rejected-by-tag-format", appending(
        string_node("plainstr"), product_node("plaintarget", [("kind", "plainstr")]),
        union_node("bad", [branch("plaintarget", "UPPER", INTERNAL_TAG)])))
    case("lb08", "form-without-sealed-target", appending(union_node("bad", [
        branch("recA", "refd", INTERNAL_TAG)])))
    case("lb08", "sealed-target-without-form", appending(
        sealed_node("orphan", "orphan"), union_node("bad", [branch("orphan", "orphan", INTERNAL_TAG)])))
    case("lb09", "duplicate-member-key", appending(union_node("bad", [
        branch("truth", "named", member_shape(("k", ABSENT), ("k", ABSENT)))])))
    case("lb09", "member-format-undefined", appending(union_node("bad", [
        branch("truth", "named", member_shape(("k", format_test("none"))))])))
    case("lb10", "sealed-without-tag-model", on_profile(lambda profile: profile.update(tag=None)))
    case("lb10", "sealed-form-undefined", appending(sealed_node("bad", "nosuchform")))
    case("lb10", "duplicate-refinement-key", appending(sealed_node("bad", "refd", [
        ("target", leaf_string()), ("target", leaf_string())])))
    case("lb10", "refinement-key-undeclared", appending(sealed_node("bad", "refd", [("other", leaf_string())])))
    case("lb10", "refinement-leaf-kind-differs", appending(sealed_node("bad", "refd", [
        ("target", leaf_integer(domain="integer"))])))
    case("lb11", "internal-tag-target-not-object", appending(union_node("bad", [
        branch("truth", "boolx", INTERNAL_TAG)])))
    case("lb12", "extras-key-format-undefined", appending(extras_node("bad", named("none"))))
    case("lb13", "wrapper-undefined", appending(string_node("bad", wrapper="none")))
    case("lb13", "wrapper-with-bytes-payload", appending(string_node("bad", wrapper="bytewrap")))
    case("lb13", "format-undefined", appending(string_node("bad", format=named("none"))))
    for name, rule in bad_format_rules():
        if name in LEAF_FORMAT_RULES:
            case("lb13", f"inline-{name}", appending(string_node("bad", format=inline(rule))))
    case("lb13", "length-bound-reversed", appending(string_node("bad", lengths=[length_bound("5", "3")])))
    case("lb13", "second-length-bound-reversed", appending(string_node("bad", lengths=[
        length_bound("1", "3"), length_bound("5", "3", "Graphemes")])))
    case("lb14", "bound-reversed", appending(integer_node("bad", minimum="5", maximum="3")))
    case("lb14", "domain-undefined", appending(integer_node("bad", domain="none")))
    case("lb15", "scale-differs", appending(decimal_node("bad", decimal_bound("1", "1"), decimal_bound("5", "2"))))
    case("lb15", "bound-reversed", appending(decimal_node("bad", decimal_bound("5", "2"), decimal_bound("1", "2"))))
    case("lb16", "array-bound-reversed", appending(array_node("bad", "truth", "5", "3")))
    case("lb16", "bytes-bound-reversed", appending(bytes_node("bad", "5", "3")))
    case("lb17", "tag-field-missing", appending(
        product_node("target", [("other", "tagstr")]), union_node("bad", [branch("target", "pa", INTERNAL_TAG)])))
    case("lb17", "tag-field-not-string", appending(
        integer_node("count"), product_node("target", [("kind", "count")]),
        union_node("bad", [branch("target", "pa", INTERNAL_TAG)])))
    case("lb17", "tag-field-const-differs", appending(
        string_node("fixed", const_value="other"), product_node("target", [("kind", "fixed")]),
        union_node("bad", [branch("target", "pa", INTERNAL_TAG)])))
    case("lb17", "tag-field-length-rejects", appending(
        string_node("short", lengths=[length_bound(None, "1")]), product_node("target", [("kind", "short")]),
        union_node("bad", [branch("target", "pa", INTERNAL_TAG)])))
    case("lb18", "duplicate-kind-selector", appending(union_node("bad", [
        branch("truth", "first", kind_selector("String")), branch("unit", "second", kind_selector("String"))])))
    case("lb18", "duplicate-member-shape-selector", appending(union_node("bad", [
        branch("truth", "first", member_shape(("k", ABSENT))),
        branch("unit", "second", member_shape(("k", ABSENT)))])))
    case("lb19", "string-const-rejected-by-format", appending(string_node(
        "bad", format=named("tagname"), const_value="UPPER")))
    case("lb19", "string-enum-rejected-by-format", appending(string_node(
        "bad", format=named("tagname"), enum_values=["fine", "UPPER"])))
    case("lb19", "string-default-rejected-by-format", appending(string_node(
        "bad", format=named("tagname"), default_value="UPPER")))
    case("lb19", "string-const-rejected-by-length", appending(string_node(
        "bad", lengths=[length_bound(None, "2")], const_value="abc")))
    case("lb19", "integer-const-outside-domain", appending(integer_node("bad", domain="integer", const_value="100")))
    case("lb19", "integer-enum-outside-domain", appending(integer_node(
        "bad", domain="integer", enum_values=["1", "100"])))
    case("lb19", "integer-default-outside-domain", appending(integer_node(
        "bad", domain="integer", default_value="-100")))
    case("lb19", "integer-const-below-minimum", appending(integer_node(
        "bad", domain="integer", minimum="5", const_value="3")))


def declare_profile_predicates(declare, declare_kind) -> None:
    label = "profile-predicate"

    def case(reason, name, change):
        declare(label, f"{reason}-{name}", on_profile(change), reason)

    def set_in(path, value):
        return lambda profile: set_path(profile, path, value)

    case("pr01", "reference-identity-empty", set_in(["reference", "identity"], ""))
    case("pr01", "reference-revision-empty", set_in(["reference", "revision"], ""))
    case("pr01", "reference-digest-empty", set_in(["reference", "content_digest"], ""))
    case("pr01", "integer-domain-reference-empty", set_in(["integer_domains", 0, "reference", "identity"], ""))
    case("pr01", "format-binding-reference-empty", set_in(["format_bindings", 0, "reference", "revision"], ""))
    case("pr01", "bytes-policy-reference-empty", set_in(
        ["bytes_policy"], bytes_policy(reference=dict(profile_ref(), identity=""))))
    case("pr01", "grapheme-rules-reference-identity-empty", set_in(
        ["grapheme_rules"], grapheme_rules(reference=dict(profile_ref(), identity=""))))
    case("pr01", "grapheme-rules-reference-digest-empty", set_in(
        ["grapheme_rules"], grapheme_rules(reference=dict(profile_ref(), content_digest=""))))
    case("pr02", "integer-domain-name-duplicate", lambda profile: profile["integer_domains"].append(
        copy.deepcopy(profile["integer_domains"][0])))
    case("pr02", "integer-domain-name-empty", set_in(["integer_domains", 0, "name"], ""))
    case("pr03", "range-reversed", set_in(
        ["integer_domains", 0, "range"], record_tag("Inclusive", minimum="5", maximum="-5")))
    case("pr04", "forms-empty", set_in(["integer_domains", 0, "forms"], []))
    case("pr05", "default-domain-undefined", set_in(["default_integer_domain"], "none"))
    case("pr05", "default-domain-empty", set_in(["default_integer_domain"], ""))
    case("pr06", "format-name-duplicate", lambda profile: profile["format_bindings"].append(
        copy.deepcopy(profile["format_bindings"][0])))
    case("pr06", "format-name-empty", set_in(["format_bindings", 1, "name"], ""))
    for name, rule in bad_format_rules():
        case("pr07", name, lambda profile, rule=rule: profile["format_bindings"].append(binding("bad", rule)))
    case("pr07", "malformed-rule-in-first-binding", set_in(
        ["format_bindings", 0, "rule"], rule_timestamp("2100", "1970")))
    case("pr08", "wrapper-name-duplicate", set_in(["wrappers", 1, "name"], "textwrap"))
    case("pr08", "wrapper-name-empty", set_in(["wrappers", 1, "name"], ""))
    case("pr08", "wrapper-key-duplicate", set_in(["wrappers", 1, "key"], "wrapkey"))
    case("pr08", "wrapper-key-empty", set_in(["wrappers", 1, "key"], ""))
    case("pr09", "wrapper-format-undefined", set_in(["wrappers", 0, "payload"], tuple_tag("Text", "none")))
    case("pr10", "bytes-policy-wrapper-undefined", set_in(["bytes_policy"], bytes_policy(wrapper="none")))
    case("pr10", "bytes-policy-wrapper-with-text-payload", set_in(["bytes_policy"], bytes_policy(wrapper="textwrap")))
    case("pr11", "tag-key-empty", set_in(["tag", "key"], ""))
    case("pr11", "tag-key-equals-wrapper-key", set_in(["tag", "key"], "wrapkey"))
    case("pr12", "tag-format-undefined", set_in(["tag", "format"], "none"))
    case("pr13", "sealed-tag-duplicate", lambda profile: profile["tag"]["sealed"].append(
        copy.deepcopy(profile["tag"]["sealed"][0])))
    case("pr13", "sealed-tag-empty", set_in(["tag", "sealed", 0, "tag"], ""))
    case("pr13", "sealed-tag-rejected-by-tag-format", set_in(["tag", "sealed", 0, "tag"], "UPPER"))
    case("pr14", "sealed-field-key-duplicate", lambda profile: profile["tag"]["sealed"][0]["fields"].append(
        copy.deepcopy(profile["tag"]["sealed"][0]["fields"][0])))
    case("pr14", "sealed-field-key-empty", set_in(["tag", "sealed", 0, "fields", 0, "key"], ""))
    case("pr14", "sealed-field-key-equals-tag-key", set_in(["tag", "sealed", 0, "fields", 0, "key"], "kind"))
    case("pr14", "sealed-field-key-equals-wrapper-key", set_in(["tag", "sealed", 0, "fields", 0, "key"], "bytekey"))
    leaf_path = ["tag", "sealed", 0, "fields", 0, "leaf"]
    case("pr15", "leaf-wrapper-undefined", set_in(leaf_path, leaf_string(wrapper="none")))
    case("pr15", "leaf-wrapper-with-bytes-payload", set_in(leaf_path, leaf_string(wrapper="bytewrap")))
    case("pr15", "leaf-format-undefined", set_in(leaf_path, leaf_string(format=named("none"))))
    for name, rule in bad_format_rules():
        if name in LEAF_FORMAT_RULES:
            case("pr15", f"leaf-inline-{name}", set_in(leaf_path, leaf_string(format=inline(rule))))
    case("pr15", "leaf-length-bound-reversed", set_in(leaf_path, leaf_string(lengths=[length_bound("5", "3")])))
    case("pr15", "leaf-integer-domain-undefined", set_in(leaf_path, leaf_integer(domain="none")))
    case("pr15", "second-field-leaf-format-undefined", set_in(
        ["tag", "sealed", 0, "fields", 1, "leaf"], leaf_string(format=named("none"))))
    case("pr16", "grapheme-property-range-reversed", set_in(["grapheme_rules"], grapheme_rules(
        properties=[{"first": "10", "last": "5", "property": unit_tag("Other")}])))
    case("pr16", "extended-pictographic-range-reversed", set_in(["grapheme_rules"], grapheme_rules(
        extended_pictographic=[{"first": "10", "last": "5"}])))
    case("pr16", "indic-conjunct-range-reversed", set_in(["grapheme_rules"], grapheme_rules(
        indic_conjunct=[{"first": "10", "last": "5", "property": unit_tag("Linker")}])))

    def control(name, change):
        declare_kind(label, name, on_profile(change), "certificate")

    control("valid-bytes-policy-and-grapheme-rules", lambda profile: profile.update(
        bytes_policy=bytes_policy(wrapper="bytewrap"), grapheme_rules=grapheme_rules(
            properties=[{"first": "5", "last": "10", "property": unit_tag("Other")}])))
    control("valid-dfa-touching-ranges", lambda profile: profile["format_bindings"].append(
        binding("dfa", rule_dfa(transitions=(("0", "97", "98", "1"), ("0", "99", "100", "1"))))))
    control("valid-dfa-overlap-from-different-states", lambda profile: profile["format_bindings"].append(
        binding("dfa", rule_dfa(transitions=(("0", "97", "100", "1"), ("1", "99", "102", "1"))))))
    control("valid-deep-nested-rule", lambda profile: profile["format_bindings"].append(
        binding("deep", rule_nested(unit_tag("Text"), 30))))
    control("valid-tag-without-format", lambda profile: profile["tag"].update(format=None))


def declare_predicate_order(declare, declare_kind, expected_plain) -> None:
    label = "predicate-order"
    bad_wrapper = string_node("badwrapper", wrapper="none")
    duplicate_fields = product_node("badfields", [("a", "truth"), ("a", "truth")])
    duplicate_node = lambda library: library["nodes"].append(copy.deepcopy(library["nodes"][0]))
    declare(label, "lb13-first-then-lb02", appending(bad_wrapper, duplicate_fields), "lb02")
    declare(label, "lb02-first-then-lb13", appending(duplicate_fields, bad_wrapper), "lb02")
    declare(label, "lb13-before-lb02-ahead-of-the-base-nodes", prepending(bad_wrapper, duplicate_fields), "lb02")
    declare(label, "lb01-and-lb02", together(appending(duplicate_fields), duplicate_node), "lb01")
    declare(label, "lb03-and-lb02", appending(product_node("badkeys", [("wrapkey", "truth")]), duplicate_fields),
            "lb02")
    declare(label, "lb04-and-lb03", appending(
        union_node("badtags", [branch("truth", "same", kind_selector("Boolean")),
                               branch("unit", "same", kind_selector("Null"))]),
        product_node("badkeys", [("wrapkey", "truth")])), "lb03")
    declare(label, "lb09-and-lb06", appending(
        union_node("badmembers", [branch("truth", "named", member_shape(("k", ABSENT), ("k", ABSENT)))]),
        union_node("badtag", [branch("truth", "", kind_selector("Boolean"))])), "lb06")
    declare(label, "lb11-and-lb05", appending(
        union_node("badtarget", [branch("truth", "boolx", INTERNAL_TAG)]),
        union_node("badorder", [branch("truth", "rest", OTHERWISE), branch("unit", "last", kind_selector("Null"))])),
            "lb05")
    declare(label, "lb12-and-lb11", appending(
        extras_node("badextras", named("none")),
        union_node("badtarget", [branch("truth", "boolx", INTERNAL_TAG)])), "lb11")
    declare(label, "lb16-and-lb15", appending(
        array_node("badarray", "truth", "5", "3"),
        decimal_node("baddecimal", decimal_bound("1", "1"), decimal_bound("5", "2"))), "lb15")
    declare(label, "lb14-and-lb19", appending(
        integer_node("baddomain", domain="none"),
        integer_node("badconst", domain="integer", const_value="100")), "lb14")
    declare(label, "lb19-and-lb18", appending(
        string_node("badconst", format=named("tagname"), const_value="UPPER"),
        union_node("badselectors", [branch("truth", "first", kind_selector("String")),
                                    branch("unit", "second", kind_selector("String"))])), "lb18")
    declare(label, "lb18-and-lb17", appending(
        product_node("target", [("other", "tagstr")]),
        union_node("badfield", [branch("target", "pa", INTERNAL_TAG)]),
        union_node("badselectors", [branch("truth", "first", kind_selector("String")),
                                    branch("unit", "second", kind_selector("String"))])), "lb17")
    declare(label, "lb13-and-lb12", appending(
        string_node("badwrapper", wrapper="none"), extras_node("badextras", named("none"))), "lb12")
    declare(label, "lb10-and-lb09", together(
        appending(union_node("badmembers", [branch("truth", "named", member_shape(("k", ABSENT), ("k", ABSENT)))])),
        on_profile(lambda profile: profile.update(tag=None))), "lb09")

    changes = {
        "pr01": lambda profile: profile["reference"].update(identity=""),
        "pr02": lambda profile: profile["integer_domains"].append(copy.deepcopy(profile["integer_domains"][0])),
        "pr03": lambda profile: set_path(profile, ["integer_domains", 0, "range"],
                                         record_tag("Inclusive", minimum="5", maximum="-5")),
        "pr04": lambda profile: set_path(profile, ["integer_domains", 0, "forms"], []),
        "pr05": lambda profile: profile.update(default_integer_domain="none"),
        "pr06": lambda profile: profile["format_bindings"].append(copy.deepcopy(profile["format_bindings"][0])),
        "pr07": lambda profile: profile["format_bindings"].append(binding("bad", rule_timestamp("2100", "1970"))),
        "pr08": lambda profile: set_path(profile, ["wrappers", 1, "name"], "textwrap"),
        "pr09": lambda profile: set_path(profile, ["wrappers", 0, "payload"], tuple_tag("Text", "none")),
        "pr10": lambda profile: profile.update(bytes_policy=bytes_policy(wrapper="none")),
        "pr11": lambda profile: set_path(profile, ["tag", "key"], ""),
        "pr12": lambda profile: set_path(profile, ["tag", "format"], "none"),
        "pr13": lambda profile: set_path(profile, ["tag", "sealed", 0, "tag"], "UPPER"),
        "pr14": lambda profile: set_path(profile, ["tag", "sealed", 0, "fields", 0, "key"], "kind"),
        "pr15": lambda profile: set_path(profile, ["tag", "sealed", 0, "fields", 0, "leaf"],
                                         leaf_string(wrapper="none")),
        "pr16": lambda profile: profile.update(grapheme_rules=grapheme_rules(
            properties=[{"first": "10", "last": "5", "property": unit_tag("Other")}])),
    }

    def profile_order(name, first, second, reason):
        declare(label, name, together(on_profile(changes[first]), on_profile(changes[second])), reason)

    names = list(changes)
    for earlier, later in zip(names, names[1:]):
        profile_order(f"{later}-and-{earlier}", later, earlier, earlier)
    for name in names[1:]:
        if name != "pr02":
            profile_order(f"{name}-and-pr01", name, "pr01", "pr01")
    profile_order("pr16-and-pr11", "pr16", "pr11", "pr11")
    profile_order("pr15-and-pr12", "pr15", "pr12", "pr12")
    declare(label, "pr16-and-lb02", together(on_profile(changes["pr16"]), appending(duplicate_fields)), "pr16")
    declare(label, "pr07-and-lb01", together(on_profile(changes["pr07"]), duplicate_node), "pr07")
    declare(label, "pr05-and-lb01-profile-digest", together(
        on_profile(changes["pr05"]), setting(["profile", "reference", "content_digest"], "abc")), "pr05")
    declare(label, "pr01-and-lb01-profile-digest", together(
        on_profile(changes["pr01"]), setting(["profile", "reference", "content_digest"], "abc")), "pr01")
    declare(label, "pr10-and-lb10-without-tag-model", together(
        on_profile(changes["pr10"]), on_profile(lambda profile: profile.update(tag=None))), "pr10")

    mutated_expected = copy.deepcopy(expected_plain)
    mutated_expected["graph_sha256"] = ALTERNATIVE["graph_sha256"]
    declare(label, "lb02-with-basis-mismatch", appending(duplicate_fields), "lb02", mutated_expected)
    declare(label, "pr01-with-basis-mismatch", on_profile(changes["pr01"]), "pr01", mutated_expected)

    def unresolved(exchange):
        exchange["entrypoints"].append({"identity": "unresolved-entry", "definition": "missing-definition"})

    def duplicated(exchange):
        exchange["entrypoints"] = [exchange["entrypoints"][0], exchange["entrypoints"][0]]

    def empty_identity(exchange):
        exchange["entrypoints"][0]["identity"] = ""

    def foreign_schema(exchange):
        exchange["schema"] = "ncoh-checked-generation@9"

    def no_entrypoints(exchange):
        exchange["entrypoints"] = []

    broken_library = together(appending(duplicate_fields), setting(["profile", "reference", "identity"], ""))
    declare_kind(label, "entrypoint-unresolved-and-library-invalid", broken_library, "entrypoint_unresolved",
                 unresolved)
    declare_kind(label, "entrypoint-duplicate-and-library-invalid", broken_library, "entrypoint_duplicate",
                 duplicated)
    declare_kind(label, "entrypoint-identity-empty-and-library-invalid", broken_library,
                 "entrypoint_identity_empty", empty_identity)
    declare_kind(label, "entrypoints-empty-and-library-invalid", broken_library, "entrypoints_empty",
                 no_entrypoints)
    declare_kind(label, "schema-and-library-invalid", broken_library, "schema", foreign_schema)


def declare_decode_stage(builder, plain, expected_plain) -> None:
    label = "decode-stage"

    def decode_case(name, change, reason):
        exchange = copy.deepcopy(plain)
        change(exchange)
        builder.add(f"{label}/{name}", request_text(exchange, expected_plain), {label},
                    [check_reason("decode", reason)])

    def schema_case(name, change, checks):
        exchange = copy.deepcopy(plain)
        exchange["schema"] = "ncoh-checked-generation@9"
        change(exchange)
        builder.add(f"{label}/{name}", request_text(exchange, expected_plain), {label}, checks)

    def put(key, value):
        return lambda exchange: exchange.__setitem__(key, copy.deepcopy(value))

    def drop(path):
        def change(exchange):
            target = exchange
            for step in path[:-1]:
                target = target[step]
            del target[path[-1]]
        return change

    def at(path, value):
        return lambda exchange: set_path(exchange, path, value)

    def signatures_number_without_entrypoints(exchange):
        exchange["signatures"] = 5
        exchange["entrypoints"] = []

    def duplicate_entrypoints_without_nodes(exchange):
        exchange["entrypoints"] = [exchange["entrypoints"][0], exchange["entrypoints"][0]]
        del exchange["signatures"]["nodes"]

    def empty_entrypoints_without_nodes(exchange):
        exchange["entrypoints"] = []
        del exchange["signatures"]["nodes"]

    decode_case("signatures-null", put("signatures", None), "exchange.syntax")
    decode_case("signatures-number-and-entrypoints-empty", signatures_number_without_entrypoints, "exchange.syntax")
    decode_case("entrypoints-duplicate-and-nodes-missing", duplicate_entrypoints_without_nodes, "exchange.syntax")
    decode_case("entrypoints-empty-and-nodes-missing", empty_entrypoints_without_nodes, "exchange.syntax")
    decode_case("entrypoint-identity-number", at(["entrypoints", 0, "identity"], 1), "exchange.syntax")
    decode_case("entrypoint-definition-number", at(["entrypoints", 0, "definition"], 1), "exchange.syntax")
    decode_case("entrypoint-identity-null", at(["entrypoints", 0, "identity"], None), "exchange.syntax")
    decode_case("entrypoint-extra-key", at(["entrypoints", 0, "extra"], 1), "exchange.unknownField")
    decode_case("entrypoint-definition-missing", drop(["entrypoints", 0, "definition"]), "exchange.syntax")
    decode_case("entrypoints-null", put("entrypoints", None), "exchange.syntax")
    decode_case("entrypoints-string", put("entrypoints", "x"), "exchange.syntax")
    decode_case("entrypoints-missing", drop(["entrypoints"]), "exchange.syntax")
    decode_case("composition-missing", drop(["composition"]), "exchange.syntax")
    decode_case("basis-field-number", at(["basis", "graph_sha256"], 5), "exchange.syntax")
    decode_case("basis-extra-key", at(["basis", "extra"], 1), "exchange.unknownField")
    decode_case("basis-profile-string", at(["basis", "profile"], "x"), "exchange.syntax")
    decode_case("basis-missing", drop(["basis"]), "exchange.syntax")
    decode_case("library-extra-key", at(["signatures", "extra"], 1), "exchange.unknownField")
    decode_case("library-nodes-null", at(["signatures", "nodes"], None), "exchange.syntax")
    decode_case("library-profile-missing-key", drop(["signatures", "profile", "tag"]), "exchange.syntax")
    decode_case("library-profile-extra-key", at(["signatures", "profile", "extra"], 1), "exchange.unknownField")
    decode_case("library-source-digest-number", at(["signatures", "sources", 0, "content_digest"], 1),
                "exchange.syntax")
    decode_case("library-schema-number", at(["signatures", "schema"], 1), "exchange.syntax")
    decode_case("definition-shape-unknown-tag", at(["signatures", "definitions", 0, "shape", "tag"], "NoSuchTag"),
                "exchange.unknownTag")
    decode_case("node-shape-extra-key", at(["signatures", "nodes", 0, "shape", "extra"], 1),
                "exchange.unknownField")

    schema_case("schema-mismatch-and-basis-field-number", at(["basis", "graph_sha256"], 5), [check_kind("schema")])
    schema_case("schema-mismatch-and-signatures-null", put("signatures", None), [check_kind("schema")])
    schema_case("schema-mismatch-and-extra-key", put("extra", 1), [check_reason("decode", "exchange.unknownField")])
    schema_case("schema-mismatch-and-entrypoints-missing", drop(["entrypoints"]),
                [check_reason("decode", "exchange.syntax")])


def declare_library_shape(declare_kind) -> None:
    label = "library-shape"
    declare_kind(label, "alias-cycle-two-nodes",
                 appending(alias_node("loop-a", "loop-b"), alias_node("loop-b", "loop-a")), "certificate")
    declare_kind(label, "alias-cycle-self", appending(alias_node("loop-self", "loop-self")), "certificate")
    declare_kind(label, "alias-chain-without-cycle",
                 appending(alias_node("chain-a", "chain-b"), alias_node("chain-b", "truth")), "certificate")
    declare_kind(label, "alias-cycle-through-definition", together(
        appending(alias_node("loop-a", "loop-b"), alias_node("loop-b", "loop-a")),
        setting(["definitions", 0, "shape", "value"], "loop-a")), "certificate")


def composition_digest(value) -> str:
    return exhaustive.sha(value)


def graph_digest(library) -> str:
    def definition_projection(definition):
        projected = copy.deepcopy(definition)
        if projected["shape"]["tag"] == "Operation":
            for outcome in projected["shape"]["value"]["outcomes"]:
                outcome["cause"] = {"tag": outcome["cause"]["tag"]}
        return projected

    return composition_digest({
        "profile": library["profile"],
        "nodes": sorted(library["nodes"], key=lambda item: item["id"]),
        "definitions": [definition_projection(item) for item in sorted(library["definitions"],
                                                                        key=lambda item: item["id"])]})


def get_path(root, path):
    target = root
    for step in path:
        target = target[step]
    return target


def requirement(identifier="req", token_type="truth", mode="Read", multiplicity="1", required_revision="0",
                identity=None):
    return {"id": identifier, "token_type": token_type, "mode": unit_tag(mode), "multiplicity": multiplicity,
            "required_revision": required_revision, "identity": identity or unit_tag("Any")}


def initial_input(identifier="arg", type_id="truth", source=None, resource=None):
    return {"id": identifier, "contract": slot(type_id), "source": source or unit_tag("Argument"),
            "resource": resource}


def initial_lot(identifier="lot1", token_type="truth"):
    return {"id": identifier, "token_type": token_type, "producer": record_tag("Initial", identity="i", revision="1"),
            "revision": "1", "quantity": "1", "provenance": "p"}


def guard_declaration(identifier="g1", source_type="truth", kind=None):
    return {"id": identifier, "source_type": source_type, "path": [], "kind": kind or unit_tag("Presence")}


def construction_rule(identity="c1", type_id="truth", nested=(), constraints=()):
    return {"identity": identity, "type_id": type_id, "nested_fields": list(nested),
            "field_constraints": list(constraints)}


def failure_embedding(function, identifier="fe1", type_id="truth"):
    return {"id": identifier, "origin": record_tag("Function", function=function, outcome="refused"),
            "contract": slot(type_id), "final_resources": []}


ACCEPTED = "accepted"
WIRE_SUM_EXPECTATION = ("unknownTag", "unknownTag", "unknownField", "syntax")


def sum_variants(base, expectation=WIRE_SUM_EXPECTATION):
    extra = copy.deepcopy(base)
    extra["extra"] = 1
    return list(zip(("unknown-tag", "unknown-tag-and-extra-key", "known-tag-and-extra-key", "tag-missing"),
                    (unit_tag("Bogus"), {"tag": "Bogus", "extra": 1}, extra, {}), expectation))


def add_second_stage_cases(builder, plain, composition, expected_plain, expected_composition) -> None:
    def composition_exchange(library_change=None, composition_change=None, stale_problem_basis=False):
        exchange = copy.deepcopy(composition)
        expected = copy.deepcopy(expected_composition)
        if library_change is not None:
            old = graph_digest(exchange["signatures"])
            if old != exchange["basis"]["graph_sha256"]:
                raise RuntimeError("the graph digest method does not match the generator")
            library_change(exchange["signatures"])
            new = graph_digest(exchange["signatures"])
            exchange = json.loads(json.dumps(exchange).replace(old, new))
            expected["graph_sha256"] = new
            if stale_problem_basis:
                exchange["composition"]["problem"]["basis"]["graph_sha256"] = old
        if composition_change is not None:
            composition_change(exchange["composition"])
        digest = composition_digest(exchange["composition"])
        exchange["basis"]["problem_sha256"] = digest
        expected["problem_sha256"] = digest
        exchange["basis"]["observations_sha256"] = exhaustive.observations_digest(exchange["composition"])
        expected["observations_sha256"] = exchange["basis"]["observations_sha256"]
        return exchange, expected

    def add(label, name, exchange_and_expected, check):
        exchange, expected = exchange_and_expected
        builder.add(f"{label}/{name}", request_text(exchange, expected), {label}, [check])

    def problem_case(label, name, change, check, library_change=None):
        add(label, name, composition_exchange(
            library_change, lambda wrapper: change(wrapper["problem"])), check)

    def derivation_case(name, change, check, label="composition-derivation"):
        add(label, name, composition_exchange(None, lambda wrapper: change(wrapper["derivation"])), check)

    def reason(kind, tag):
        return check_accepted() if tag == ACCEPTED else check_reason(kind, tag)

    def setter(path, value):
        return lambda root: set_path(root, path, value)

    def drop(path):
        def change(root):
            del get_path(root, path[:-1])[path[-1]]
        return change

    def chain(*changes):
        def apply(root):
            for change in changes:
                change(root)
        return apply

    problem_label = "composition-problem"
    first_function = composition["composition"]["problem"]["signatures"][0]["reference"]
    operation_outcomes = ["signatures", 0, "outcomes"]
    handler = ["signatures", 1]

    def production_case(name, productions, tag):
        problem_case(problem_label, name, setter(operation_outcomes + [0, "produced_resources"], productions),
                     reason("composition", tag))

    production_case("produced-resource-id-duplicate", [resource(), resource()], "invalidSignature")
    production_case("produced-resource-id-empty", [resource("")], "invalidSignature")
    production_case("produced-resource-token-type-empty", [resource("token", "")], "invalidSignature")
    production_case("produced-resource-added-to-operation-outcome", [resource()], "invalidSignature")
    problem_case(problem_label, "output-port-id-duplicate", lambda problem: problem["signatures"][0]["outcomes"][0][
        "value_ports"].append(copy.deepcopy(problem["signatures"][0]["outcomes"][0]["value_ports"][0])),
                 reason("composition", "invalidSignature"))

    origin_path = operation_outcomes + [0, "cause", "fields", "origin"]
    for name, value in (("string", "x"), ("number", 5), ("null", None), ("array", [])):
        problem_case(problem_label, f"cause-origin-source-{name}", setter(origin_path + ["source"], value),
                     reason("composition", "syntax"))
    problem_case(problem_label, "cause-origin-source-missing", drop(origin_path + ["source"]),
                 reason("composition", "syntax"))
    problem_case(problem_label, "cause-origin-extra-key", setter(origin_path + ["extra"], 1),
                 reason("composition", "unknownField"))
    problem_case(problem_label, "cause-origin-locator-string", setter(origin_path + ["locator"], "x"),
                 reason("composition", "syntax"))

    def initial_inputs(*items):
        return setter(["initial_inputs"], list(items))

    bogus_source = unit_tag("Bogus")
    problem_case(problem_label, "initial-input-id-number-and-source-tag-unknown",
                 initial_inputs(initial_input(identifier=1, source=bogus_source)), reason("composition", "syntax"))
    problem_case(problem_label, "initial-input-source-tag-unknown",
                 initial_inputs(initial_input(source=bogus_source)), reason("composition", "unknownTag"))
    problem_case(problem_label, "initial-input-contract-number-and-source-tag-unknown",
                 initial_inputs(dict(initial_input(source=bogus_source), contract=5)), reason("composition", "syntax"))
    problem_case(problem_label, "initial-input-source-tag-unknown-and-resource-number",
                 initial_inputs(initial_input(source=bogus_source, resource=5)), reason("composition", "unknownTag"))
    problem_case(problem_label, "initial-input-extra-key-and-source-tag-unknown",
                 initial_inputs(dict(initial_input(source=bogus_source), extra=1)),
                 reason("composition", "unknownField"))
    problem_case(problem_label, "initial-input-missing-resource-and-source-tag-unknown", initial_inputs(
        {key: value for key, value in initial_input(source=bogus_source).items() if key != "resource"}),
                 reason("composition", "syntax"))

    def outcome_case(name, change, tag):
        problem_case(problem_label, f"handler-outcome-{name}",
                     lambda problem: change(problem["signatures"][1]["outcomes"][0]), reason("composition", tag))

    bogus = unit_tag("Bogus")
    outcome_case("cause-tag-unknown-and-id-number", lambda o: o.update(cause=bogus, id=1), "unknownTag")
    outcome_case("id-number-and-form-tag-unknown", lambda o: o.update(id=1, form=bogus), "syntax")
    outcome_case("form-tag-unknown-and-value-ports-number", lambda o: o.update(form=bogus, value_ports=5),
                 "unknownTag")
    outcome_case("value-ports-number-and-cause-tag-unknown", lambda o: o.update(value_ports=5, cause=bogus),
                 "unknownTag")
    outcome_case("form-tag-unknown-and-produced-resources-number",
                 lambda o: o.update(form=bogus, produced_resources=5), "unknownTag")
    outcome_case("extra-key-and-cause-tag-unknown", lambda o: o.update(extra=1, cause=bogus), "unknownField")
    outcome_case("missing-key-and-cause-tag-unknown", lambda o: (o.pop("produced_resources"), o.update(cause=bogus)),
                 "syntax")
    outcome_case("cause-missing-and-form-tag-unknown", lambda o: (o.pop("cause"), o.update(form=bogus)), "syntax")

    def requirement_case(name, item, tag):
        problem_case(problem_label, f"resource-requirement-{name}",
                     lambda problem: problem["signatures"][1].update(resource_inputs=[item]),
                     reason("composition", tag))

    requirement_case("id-number-and-mode-tag-unknown", dict(requirement(mode="Read"), id=1, mode=bogus), "syntax")
    requirement_case("token-type-number-and-mode-tag-unknown", dict(requirement(), token_type=1, mode=bogus),
                     "syntax")
    requirement_case("mode-tag-unknown-and-multiplicity-number", dict(requirement(), mode=bogus, multiplicity=1),
                     "unknownTag")
    requirement_case("identity-tag-unknown-and-required-revision-number",
                     dict(requirement(), identity=bogus, required_revision=1), "syntax")
    requirement_case("identity-tag-unknown", dict(requirement(), identity=bogus), "unknownTag")
    requirement_case("mode-tag-unknown", dict(requirement(), mode=bogus), "unknownTag")
    requirement_case("extra-key-and-mode-tag-unknown", dict(requirement(), mode=bogus, extra=1), "unknownField")
    requirement_case("token-type-empty", requirement(token_type=""), "unresolvedType")

    def signature_case(name, change, tag):
        problem_case(problem_label, f"signature-{name}", lambda problem: change(problem["signatures"][1]),
                     reason("composition", tag))

    signature_case("reference-number-and-form-tag-unknown", lambda s: s.update(reference=1, form=bogus), "syntax")
    signature_case("form-tag-unknown-and-assumption-ref-number", lambda s: s.update(form=bogus, assumption_ref=1),
                   "unknownTag")
    signature_case("effect-tag-unknown-and-inputs-number", lambda s: s.update(effect=bogus, inputs=5), "unknownTag")
    signature_case("inputs-number-and-handles-failure-tag-unknown",
                   lambda s: s.update(inputs=5, handles_failure=bogus), "syntax")
    signature_case("form-tag-unknown-and-effect-tag-unknown", lambda s: s.update(form=bogus, effect=bogus),
                   "unknownTag")
    signature_case("extra-key-and-form-tag-unknown", lambda s: s.update(form=bogus, extra=1), "unknownField")

    for name, value, tag in (("missing-definition", "missing", "invalidSignature"),
                             ("value-definition", "value", "invalidSignature"),
                             ("number", 5, "syntax"), ("empty", "", "invalidSignature")):
        problem_case(problem_label, f"signature-form-operation-{name}", setter(
            ["signatures", 0, "form"], tuple_tag("Operation", value)), reason("composition", tag))
    problem_case(problem_label, "signature-form-operation-on-handler",
                 setter(["signatures", 1, "form"], tuple_tag("Operation", "operation")),
                 reason("composition", "invalidSignature"))
    problem_case(problem_label, "signature-form-operation-extra-key", setter(
        ["signatures", 0, "form"], dict(tuple_tag("Operation", "operation"), extra=1)),
                 reason("composition", "unknownField"))

    empty_ref_cases = [
        ("input-port-type-id", setter(handler + ["inputs", 0, "contract", "type_id"], ""), "unresolvedType"),
        ("output-port-type-id", setter(operation_outcomes + [0, "value_ports", 0, "contract", "type_id"], ""),
         "invalidSignature"),
        ("handler-output-port-type-id", setter(handler + ["outcomes", 0, "value_ports", 0, "contract", "type_id"], ""),
         "unresolvedType"),
        ("initial-input-type-id", initial_inputs(initial_input(type_id="")), "unresolvedType"),
        ("initial-resource-token-type", setter(["initial_resources"], [initial_lot(token_type="")]),
         "unresolvedType"),
        ("goal-output-type-id", setter(["goal", "outputs", 0, "contract", "type_id"], ""), "unresolvedType"),
        ("goal-failure-type-id", setter(["goal", "failures"], [failure_embedding(first_function, type_id="")]),
         "unresolvedType"),
        ("projection-source-type", setter(["invocation_domain", "permitted_projections"],
                                          [{"source_type": "", "path": []}]), "unresolvedType"),
        ("construction-type-id", setter(["invocation_domain", "permitted_constructions"],
                                        [construction_rule(type_id="")]), "unresolvedType"),
        ("guard-source-type", setter(["invocation_domain", "guards"], [guard_declaration(source_type="")]),
         "unresolvedType"),
        ("guard-validate-type-id", setter(["invocation_domain", "guards"], [guard_declaration(
            kind=tuple_tag("Validate", slot("")))]), "unresolvedType"),
    ]
    for name, change, tag in empty_ref_cases:
        problem_case(problem_label, f"empty-{name}", change, reason("composition", tag))
    problem_case(problem_label, "empty-goal-failure-type-id-with-valid-embedding",
                 setter(["goal", "failures"], [failure_embedding(first_function)]), check_not_decode())

    for name, path in (("input-port-contract", handler + ["inputs", 0, "contract"]),
                       ("output-port-contract", operation_outcomes + [0, "value_ports", 0, "contract"]),
                       ("goal-output-contract", ["goal", "outputs", 0, "contract"])):
        problem_case(problem_label, f"type-ref-key-extra-in-{name}", setter(path + ["type_ref"], "truth"),
                     reason("composition", "unknownField"))
        problem_case(problem_label, f"type-ref-key-replaces-type-id-in-{name}",
                     lambda problem, path=path: (get_path(problem, path).pop("type_id"),
                                                 get_path(problem, path).update(type_ref="truth")),
                     reason("composition", "unknownField"))
    problem_case(problem_label, "type-ref-key-in-initial-input-contract",
                 initial_inputs(dict(initial_input(), contract=dict(slot("truth"), type_ref="truth"))),
                 reason("composition", "unknownField"))
    problem_case(problem_label, "type-ref-key-in-guard-validate-contract", setter(
        ["invocation_domain", "guards"], [guard_declaration(kind=tuple_tag(
            "Validate", dict(slot("truth"), type_ref="truth")))]), reason("composition", "unknownField"))
    problem_case(problem_label, "type-ref-key-in-construction-rule", setter(
        ["invocation_domain", "permitted_constructions"], [dict(construction_rule(), type_ref="truth")]),
                 reason("composition", "unknownField"))

    basis_path = ["basis"]
    problem_case(problem_label, "basis-extra-key", setter(basis_path + ["extra"], 1),
                 reason("composition", "unknownField"))
    for field_name in BASIS_FIELDS:
        problem_case(problem_label, f"basis-missing-{field_name}", drop(basis_path + [field_name]),
                     reason("composition", "syntax"))
    for field_name, value in (("graph_sha256", 5), ("library_identity", 5), ("profile", "x"), ("problem_sha256", 5),
                              ("entrypoints_sha256", None), ("signature_schema", None)):
        problem_case(problem_label, f"basis-{field_name}-wrong-type", setter(basis_path + [field_name], value),
                     reason("composition", "syntax"))
    for field_name in BASIS_FIELDS:
        value = ALTERNATIVE[field_name]
        problem_case(problem_label, f"basis-{field_name}-differs", setter(basis_path + [field_name], value),
                     reason("composition", "syntax"))
    problem_case(problem_label, "basis-problem-digest-present", setter(basis_path + ["problem_sha256"], "7" * 64),
                 reason("composition", "syntax"))
    problem_case(problem_label, "basis-null", setter(basis_path, None), reason("composition", "syntax"))
    problem_case(problem_label, "basis-string", setter(basis_path, "x"), reason("composition", "syntax"))
    problem_case(problem_label, "problem-extra-key", setter(["extra"], 1), reason("composition", "unknownField"))
    problem_case(problem_label, "problem-missing-bounds", drop(["bounds"]), reason("composition", "syntax"))
    problem_case(problem_label, "problem-signatures-not-array", setter(["signatures"], 5),
                 reason("composition", "syntax"))
    problem_case(problem_label, "problem-identity-number", setter(["identity"], 1), reason("composition", "syntax"))
    problem_case(problem_label, "problem-basis-extra-key-and-signature-form-tag-unknown",
                 lambda problem: (problem["basis"].update(extra=1), problem["signatures"][0].update(form=bogus)),
                 reason("composition", "unknownField"))
    problem_case(problem_label, "problem-basis-differs-and-signature-form-tag-unknown",
                 lambda problem: (problem["basis"].update(library_identity="other"),
                                  problem["signatures"][0].update(form=bogus)), reason("composition", "syntax"))

    def graphemes(library):
        library["profile"]["grapheme_rules"] = grapheme_rules(properties=[
            {"first": "5", "last": "10", "property": unit_tag("Other")}])

    add(problem_label, "grapheme-rules-library-accepted", composition_exchange(graphemes), check_accepted())
    problem_case(problem_label, "grapheme-rules-library-goal-type-empty", setter(
        ["goal", "outputs", 0, "contract", "type_id"], ""), reason("composition", "unresolvedType"), graphemes)
    problem_case(problem_label, "grapheme-rules-library-problem-extra-key", setter(["extra"], 1),
                 reason("composition", "unknownField"), graphemes)
    problem_case(problem_label, "grapheme-rules-library-produced-resource-duplicate", setter(
        operation_outcomes + [0, "produced_resources"], [resource(), resource()]),
                 reason("composition", "invalidSignature"), graphemes)
    add(problem_label, "grapheme-rules-library-problem-basis-stale", composition_exchange(
        graphemes, None, stale_problem_basis=True), reason("composition", "syntax"))
    add(problem_label, "grapheme-rules-library-derivation-selection-tag-unknown", composition_exchange(
        graphemes, lambda wrapper: wrapper["derivation"].update(selection=bogus)), reason("composition", "unknownTag"))
    add(problem_label, "grapheme-rules-library-derivation-extra-key", composition_exchange(
        graphemes, lambda wrapper: wrapper["derivation"].update(extra=1)), reason("composition", "unknownField"))

    def grapheme_reversed(library):
        library["profile"]["grapheme_rules"] = grapheme_rules(properties=[
            {"first": "10", "last": "5", "property": unit_tag("Other")}])

    add(problem_label, "grapheme-rules-library-range-reversed", composition_exchange(grapheme_reversed),
        reason("declaration", "pr16"))
    add(problem_label, "grapheme-rules-library-reference-empty", composition_exchange(
        lambda library: library["profile"].update(grapheme_rules=grapheme_rules(
            reference=dict(profile_ref(), identity="")))), reason("declaration", "pr01"))
    add(problem_label, "grapheme-rules-library-extra-key", composition_exchange(
        lambda library: library["profile"].update(grapheme_rules=dict(grapheme_rules(), extra=1))),
        reason("decode", "exchange.unknownField"))

    derivation_label = "composition-derivation"
    plan_root = ["plan", "root"]
    node_path = plan_root + ["node"]
    arm_return = node_path + ["fields", "arms", 0, 1, "node"]
    binding_path = arm_return + ["value", "value", 0, 1]
    producer_path = binding_path + ["fields", "value", "producer"]
    witness_trace = ["witness", "resource_traces", 0]
    snapshot_changed = setter(["witness", "input_snapshot", "identity"], "other")
    tree_failure = setter(producer_path, bogus)
    selection_failure = setter(["selection"], bogus)
    trace_failure = setter(witness_trace + ["trace", "terminal", "value", 0, 1, "fields", "value", "producer"], bogus)

    derivation_case("extra-key", setter(["extra"], 1), reason("composition", "unknownField"))
    derivation_case("selection-missing", drop(["selection"]), reason("composition", "syntax"))
    derivation_case("plan-extra-key", setter(["plan", "extra"], 1), reason("composition", "unknownField"))
    derivation_case("witness-extra-key", setter(["witness", "extra"], 1), reason("composition", "unknownField"))
    derivation_case("plan-root-missing", drop(plan_root), reason("composition", "syntax"))
    derivation_case("witness-resource-traces-missing", drop(["witness", "resource_traces"]),
                    reason("composition", "syntax"))
    derivation_case("extra-key-and-plan-root-missing", chain(setter(["extra"], 1), drop(plan_root)),
                    reason("composition", "unknownField"))
    derivation_case("selection-missing-and-plan-extra-key", chain(drop(["selection"]), setter(["plan", "extra"], 1)),
                    reason("composition", "syntax"))
    derivation_case("plan-extra-key-and-witness-missing-key",
                    chain(setter(["plan", "extra"], 1), drop(["witness", "resource_traces"])),
                    reason("composition", "unknownField"))
    derivation_case("witness-extra-key-and-plan-missing-key",
                    chain(setter(["witness", "extra"], 1), drop(plan_root)), reason("composition", "syntax"))
    derivation_case("witness-extra-key-and-snapshot-changed",
                    chain(setter(["witness", "extra"], 1), snapshot_changed), reason("composition", "unknownField"))
    derivation_case("plan-extra-key-and-snapshot-changed",
                    chain(setter(["plan", "extra"], 1), snapshot_changed), reason("composition", "unknownField"))
    derivation_case("snapshot-changed", snapshot_changed, reason("composition", "syntax"))
    derivation_case("snapshot-changed-and-tree-failure", chain(snapshot_changed, tree_failure),
                    reason("composition", "syntax"))
    derivation_case("snapshot-changed-and-selection-tag-unknown", chain(snapshot_changed, selection_failure),
                    reason("composition", "syntax"))
    derivation_case("tree-failure", tree_failure, reason("composition", "unknownTag"))
    derivation_case("tree-failure-and-selection-tag-unknown", chain(tree_failure, selection_failure),
                    reason("composition", "unknownTag"))
    derivation_case("selection-tag-unknown", selection_failure, reason("composition", "unknownTag"))
    derivation_case("selection-tag-unknown-and-trace-failure", chain(selection_failure, trace_failure),
                    reason("composition", "unknownTag"))
    derivation_case("trace-failure", trace_failure,
                    check_derivation_verified(reason("composition", "unknownTag")))
    derivation_case("trace-failure-and-initial-membership-number",
                    chain(trace_failure, setter(["witness", "initial_membership"], 5)),
                    check_derivation_verified(reason("composition", "unknownTag")))
    derivation_case("tree-failure-and-trace-failure", chain(tree_failure, trace_failure),
                    reason("composition", "unknownTag"))
    derivation_case("selection-unique-extra-key", setter(["selection"], record_tag(
        "Unique", closure={}, canonical_plan="x", extra=1)),
                    check_derivation_verified(reason("composition", "unknownField")))
    derivation_case("selection-any-feasible-extra-key", setter(["selection", "extra"], 1),
                    reason("composition", "unknownField"))
    derivation_case("selection-unique-closure-missing", setter(["selection"], record_tag("Unique", canonical_plan="x")),
                    check_derivation_verified(reason("composition", "syntax")))
    derivation_case("plan-input-identity-number", setter(["plan", "input_identity"], 1),
                    reason("composition", "syntax"))
    derivation_case("plan-root-rank-number", setter(plan_root + ["rank"], 1), reason("composition", "syntax"))
    derivation_case("plan-root-extra-key", setter(plan_root + ["extra"], 1), reason("composition", "unknownField"))

    empty_types_path = next(path for path in find_key_paths(composition["composition"]["derivation"], "empty_types"))
    derivation_case("inclusion-empty-types-empty-string", setter(empty_types_path[:-1] + ["empty_types"], [""]),
                    check_derivation_verified(check_reason("composition", "inclusion")))
    derivation_case("inclusion-empty-types-unknown-type", setter(empty_types_path[:-1] + ["empty_types"], ["none"]),
                    check_derivation_verified(check_reason("composition", "inclusion")))
    derivation_case("inclusion-empty-types-number", setter(empty_types_path[:-1] + ["empty_types"], [1]),
                    reason("composition", "syntax"))

    derivation_sums = [
        ("selection", ["selection"]), ("plan-node", node_path), ("plan-return", arm_return + ["value"]),
        ("return-binding", binding_path), ("binding-compatibility", binding_path + ["fields", "compatibility"]),
        ("binding-producer", producer_path), ("trace-step", witness_trace + ["trace", "steps", 0]),
        ("trace-terminal", witness_trace + ["trace", "terminal"]),
    ]
    for name, path in derivation_sums:
        base = get_path(composition["composition"]["derivation"], path)
        for variant, value, tag in sum_variants(base):
            expected = reason("composition", tag)
            if name in ("trace-step", "trace-terminal"):
                expected = check_derivation_verified(expected)
            derivation_case(f"sum-{name}-{variant}", setter(path, value), expected, "tagged-union")

    problem_sums = [
        ("function-form", handler + ["form"]), ("function-effect", handler + ["effect"]),
        ("outcome-form", handler + ["outcomes", 0, "form"]), ("outcome-cause", handler + ["outcomes", 0, "cause"]),
        ("input-source-constraint", handler + ["inputs", 0, "source_constraint"]),
        ("handles-failure", handler + ["handles_failure"]), ("allowed-effect", ["allowed_effects", 0]),
        ("selection-policy", ["selection_policy"]), ("goal-source-constraint", ["goal", "outputs", 0, "source_constraint"]),
    ]
    prepared_sums = [
        ("initial-source", initial_inputs(initial_input()), ["initial_inputs", 0, "source"]),
        ("initial-source-slot-value", initial_inputs(initial_input(source=tuple_tag(
            "SuppliedValue", tuple_tag("Present", tuple_tag("Bool", True))))), ["initial_inputs", 0, "source", "value"]),
        ("initial-source-json-value", initial_inputs(initial_input(source=tuple_tag(
            "SuppliedValue", tuple_tag("Present", tuple_tag("Bool", True))))),
         ["initial_inputs", 0, "source", "value", "value"]),
        ("path-step", setter(handler + ["inputs", 0, "source_constraint"], record_tag(
            "ProducedBy", site="operation", outcome="refused", port="reason", path=[tuple_tag("Field", "f")])),
         handler + ["inputs", 0, "source_constraint", "fields", "path", 0]),
        ("resource-mode", setter(handler + ["resource_inputs"], [requirement()]),
         handler + ["resource_inputs", 0, "mode"]),
        ("resource-identity", setter(handler + ["resource_inputs"], [requirement()]),
         handler + ["resource_inputs", 0, "identity"]),
        ("resource-producer", setter(["initial_resources"], [initial_lot()]), ["initial_resources", 0, "producer"]),
        ("resource-lot-ref", chain(setter(["initial_resources"], [initial_lot()]), setter(
            ["goal", "final_resources"], [{"lot": tuple_tag("Initial", "lot1"), "multiplicity": "1",
                                           "revision": "1"}])), ["goal", "final_resources", 0, "lot"]),
        ("guard-kind", setter(["invocation_domain", "guards"], [guard_declaration()]),
         ["invocation_domain", "guards", 0, "kind"]),
        ("guard-kind-validate", setter(["invocation_domain", "guards"], [guard_declaration(
            kind=tuple_tag("Validate", slot("truth")))]), ["invocation_domain", "guards", 0, "kind"]),
        ("field-presence", setter(["invocation_domain", "permitted_constructions"], [construction_rule(
            constraints=[{"field": "f", "source": unit_tag("AnyCompatible"), "presence": unit_tag("Required")}])]),
         ["invocation_domain", "permitted_constructions", 0, "field_constraints", 0, "presence"]),
        ("field-source-constraint", setter(["invocation_domain", "permitted_constructions"], [construction_rule(
            constraints=[{"field": "f", "source": unit_tag("AnyCompatible"), "presence": unit_tag("Required")}])]),
         ["invocation_domain", "permitted_constructions", 0, "field_constraints", 0, "source"]),
        ("failure-embedding-origin", setter(["goal", "failures"], [failure_embedding(first_function)]),
         ["goal", "failures", 0, "origin"]),
    ]
    base_problem = composition["composition"]["problem"]
    for name, path in problem_sums:
        base = get_path(base_problem, path)
        for variant, value, tag in sum_variants(base):
            problem_case("tagged-union", f"sum-problem-{name}-{variant}", setter(path, value),
                         reason("composition", tag))
    for name, prepare, path in prepared_sums:
        prepared = copy.deepcopy(base_problem)
        prepare(prepared)
        base = get_path(prepared, path)
        for variant, value, tag in sum_variants(base):
            problem_case("tagged-union", f"sum-problem-{name}-{variant}",
                         chain(prepare, setter(path, value)), reason("composition", tag))

    rich = rich_library(plain["signatures"])

    def library_sum(name, prepare, path_of):
        library = copy.deepcopy(rich)
        library_path = path_of(library)
        prepare(library)
        base = get_path(library, library_path)
        for variant, value, tag in sum_variants(base):
            exchange = copy.deepcopy(plain)
            changed = copy.deepcopy(rich)
            prepare(changed)
            set_path(changed, library_path, value)
            exchange["signatures"] = changed
            builder.add(f"tagged-union/sum-library-{name}-{variant}", request_text(exchange, expected_plain),
                        {"tagged-union"}, [check_reason("decode", "exchange." + tag)])

    def probe(shape_node, tail):
        def prepare(library):
            library["nodes"].append(copy.deepcopy(shape_node))
        return prepare, lambda library: ["nodes", len(library["nodes"])] + tail

    def library_node_sum(name, shape_node, tail):
        prepare, path_of = probe(shape_node, tail)
        library_sum(name, prepare, path_of)

    def library_fixed_sum(name, prepare, path):
        library_sum(name, prepare, lambda library: path)

    def noop(library):
        return None

    library_fixed_sum("outcome-form", noop, ["definitions", 1, "shape", "value", "outcomes", 0, "form"])
    library_fixed_sum("outcome-cause", noop, ["definitions", 1, "shape", "value", "outcomes", 0, "cause"])
    library_fixed_sum("effect-point", noop, ["definitions", 1, "shape", "value", "effect"])
    library_fixed_sum("definition-shape", noop, ["definitions", 0, "shape"])
    library_fixed_sum("annotation-target", noop, ["annotations", 0, "target"])
    library_fixed_sum("annotation-value", noop, ["annotations", 0, "value"])
    library_fixed_sum("provenance-target", lambda library: library["provenance"].append(
        provenance_binding(unit_tag("Library"), origin())), ["provenance", 0, "target"])
    library_node_sum("value-kind", union_node("probe", [branch("truth", "kt", kind_selector("Boolean"))]),
                     ["shape", "value", "branches", 0, "selector", "value"])
    library_node_sum("member-test", union_node("probe", [branch("truth", "kt", member_shape(("k", ABSENT)))]),
                     ["shape", "value", "branches", 0, "selector", "value", 0, "test"])
    library_node_sum("branch-selector", union_node("probe", [branch("truth", "kt", kind_selector("Boolean"))]),
                     ["shape", "value", "branches", 0, "selector"])
    library_node_sum("extra-members", extras_node("probe", None), ["shape", "value", "extras"])
    library_node_sum("unknown-kind", node("probe", tuple_tag("Unknown", unit_tag("Any"))), ["shape", "value"])
    library_node_sum("node-shape", string_node("probe"), ["shape"])
    library_node_sum("format-use", string_node("probe", format=named("tagname")), ["shape", "value", "format"])
    library_node_sum("inline-format-rule", string_node("probe", format=inline(unit_tag("Text"))),
                     ["shape", "value", "format", "value"])
    library_node_sum("length-unit", string_node("probe", lengths=[length_bound("1", "2")]),
                     ["shape", "value", "lengths", 0, "unit"])
    library_fixed_sum("sealed-leaf", noop, ["profile", "tag", "sealed", 0, "fields", 0, "leaf"])
    library_fixed_sum("sealed-extras", noop, ["profile", "tag", "sealed", 0, "extras"])
    library_fixed_sum("wrapper-payload", noop, ["profile", "wrappers", 0, "payload"])
    library_fixed_sum("integer-domain", noop, ["profile", "integer_domains", 0, "range"])
    library_fixed_sum("integer-form", noop, ["profile", "integer_domains", 0, "forms", 0])
    library_fixed_sum("bytes-alphabet", lambda library: library["profile"].update(bytes_policy=bytes_policy()),
                      ["profile", "bytes_policy", "alphabet"])

    def with_graphemes(library):
        library["profile"]["grapheme_rules"] = grapheme_rules(
            properties=[{"first": "5", "last": "10", "property": unit_tag("Other")}],
            indic_conjunct=[{"first": "5", "last": "10", "property": unit_tag("Linker")}])

    library_fixed_sum("grapheme-property", with_graphemes, ["profile", "grapheme_rules", "properties", 0, "property"])
    library_fixed_sum("indic-property", with_graphemes, ["profile", "grapheme_rules", "indic_conjunct", 0, "property"])
    library_fixed_sum("format-binding-rule", noop, ["profile", "format_bindings", 0, "rule"])
    library_fixed_sum("format-binding-text-rule", noop, ["profile", "format_bindings", 1, "rule"])

    declare_natural_fields(builder, plain, rich, expected_plain)

    record_label = "record-keys"
    extra_key = {"extra": 1}

    def add_record_keys(prefix, root, add_case, skip=lambda path: False):
        seen = set()
        for path in object_paths(root):
            if skip(path):
                continue
            shape = tuple("*" if isinstance(step, int) else step for step in path)
            if shape in seen:
                continue
            seen.add(shape)
            add_case(prefix + "/" + ".".join(map(str, shape)) if shape else prefix + "/root", path)

    def derivation_extra(name, path):
        expected = reason("composition", "unknownField")
        if tuple(path[:2]) == ("witness", "resource_traces") or tuple(path[:2]) == ("selection", "fields"):
            expected = check_derivation_verified(expected)
        derivation_case(name, setter(list(path) + ["extra"], 1), expected, record_label)

    def problem_extra(name, path):
        problem_case(record_label, name, setter(list(path) + ["extra"], 1), reason("composition", "unknownField"))

    def library_extra(name, path):
        exchange = copy.deepcopy(plain)
        exchange["signatures"] = copy.deepcopy(rich)
        set_path(exchange["signatures"], list(path) + ["extra"], 1)
        builder.add(f"{record_label}/{name}", request_text(exchange, expected_plain),
                    {record_label}, [check_reason("decode", "exchange.unknownField")])

    add_record_keys("derivation", composition["composition"]["derivation"], derivation_extra,
                    lambda path: path[:2] == ("witness", "input_snapshot"))
    add_record_keys("problem", composition["composition"]["problem"], problem_extra)
    add_record_keys("library", rich, library_extra)

    closure_request = json.loads((ENTRY_DIR / "examples" / "rejected-closure-used-site.request.json").read_text(
        encoding="utf-8"))
    for variant, change in (("extra-key", lambda row: row.update(extra_key)),
                            ("extra-key-and-state-missing", lambda row: (row.pop("state"), row.update(extra_key)))):
        exchange = json.loads(closure_request["exchange"])
        expected = copy.deepcopy(closure_request["expected_basis"]["basis"])
        row = get_path(exchange["composition"], next(find_key_paths(exchange["composition"], "rejected_connections"))[:-1])
        change(row)
        digest = composition_digest(exchange["composition"])
        exchange["basis"]["problem_sha256"] = digest
        expected["problem_sha256"] = digest
        exchange["basis"]["observations_sha256"] = exhaustive.observations_digest(exchange["composition"])
        expected["observations_sha256"] = exchange["basis"]["observations_sha256"]
        builder.add(f"{record_label}/derivation/closure-row-{variant}", request_text(exchange, expected),
                    {record_label}, [check_derivation_verified(check_reason("composition", "unknownField"))])


def object_paths(value, path=()):
    if isinstance(value, dict):
        yield path
        for name, item in value.items():
            yield from object_paths(item, path + (name,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from object_paths(item, path + (index,))


def find_key_paths(value, key, path=()):
    if isinstance(value, dict):
        for name, item in value.items():
            if name == key:
                yield list(path) + [name]
            yield from find_key_paths(item, key, path + (name,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from find_key_paths(item, key, path + (index,))


def check_not_decode():
    def check(out, results):
        if failure_of(out).get("kind") == "decode":
            return f"expected a failure after the decode, got {short(out)}"
        return None
    return check


def declare_natural_fields(builder, plain, rich, expected_plain) -> None:
    label = "library-natural"

    def natural(name, change, value="-1"):
        exchange = copy.deepcopy(plain)
        library = copy.deepcopy(rich)
        change(library, value)
        exchange["signatures"] = library
        builder.add(f"{label}/{name}", request_text(exchange, expected_plain), {label},
                    [check_reason("decode", "exchange.syntax")])

    def node_field(node_builder, tail):
        return lambda library, value: (library["nodes"].append(node_builder()),
                                       set_path(library, ["nodes", len(library["nodes"]) - 1] + tail, value))

    def rule_field(rule_builder, tail):
        return lambda library, value: (library["profile"]["format_bindings"].append(binding("bad", rule_builder())),
                                       set_path(library, ["profile", "format_bindings",
                                                          len(library["profile"]["format_bindings"]) - 1, "rule"] + tail,
                                                value))

    def profile_field(prepare, path):
        return lambda library, value: (prepare(library["profile"]), set_path(library["profile"], path, value))

    def graphemes(profile):
        profile["grapheme_rules"] = grapheme_rules(
            properties=[{"first": "5", "last": "10", "property": unit_tag("Other")}],
            extended_pictographic=[{"first": "5", "last": "10"}],
            indic_conjunct=[{"first": "5", "last": "10", "property": unit_tag("Linker")}])

    def noop(profile):
        return None

    fields = [
        ("array-min-length", node_field(lambda: array_node("bad", "truth", "1", "2"), ["shape", "value", "min_length"])),
        ("array-max-length", node_field(lambda: array_node("bad", "truth", "1", "2"), ["shape", "value", "max_length"])),
        ("bytes-minimum", node_field(lambda: bytes_node("bad", "1", "2"), ["shape", "value", "minimum"])),
        ("bytes-maximum", node_field(lambda: bytes_node("bad", "1", "2"), ["shape", "value", "maximum"])),
        ("decimal-minimum-scale", node_field(lambda: decimal_node("bad", decimal_bound("1", "2"), decimal_bound("5", "2")),
                                             ["shape", "value", "minimum", "scale"])),
        ("decimal-maximum-scale", node_field(lambda: decimal_node("bad", decimal_bound("1", "2"), decimal_bound("5", "2")),
                                             ["shape", "value", "maximum", "scale"])),
        ("string-length-minimum", node_field(lambda: string_node("bad", lengths=[length_bound("1", "2")]),
                                             ["shape", "value", "lengths", 0, "minimum"])),
        ("string-length-maximum", node_field(lambda: string_node("bad", lengths=[length_bound("1", "2")]),
                                             ["shape", "value", "lengths", 0, "maximum"])),
        ("resource-production-revision", lambda library, value: (
            operation_of(library)["outcomes"][0].update(produced_resources=[resource()]),
            set_path(operation_of(library)["outcomes"][0], ["produced_resources", 0, "revision"], value))),
        ("resource-production-quantity", lambda library, value: (
            operation_of(library)["outcomes"][0].update(produced_resources=[resource()]),
            set_path(operation_of(library)["outcomes"][0], ["produced_resources", 0, "quantity"], value))),
        ("identifier-exact-length", rule_field(lambda: rule_identifier(exact="3"), ["fields", "exact_length"])),
        ("identifier-min-length", rule_field(rule_identifier, ["fields", "min_length"])),
        ("identifier-max-length", rule_field(lambda: rule_identifier(maximum="5"), ["fields", "max_length"])),
        ("labels-min-count", rule_field(rule_labels, ["fields", "min_count"])),
        ("labels-max-count", rule_field(lambda: dict(rule_labels(), fields=dict(rule_labels()["fields"], max_count="3")),
                                        ["fields", "max_count"])),
        ("labels-total-max", rule_field(lambda: dict(rule_labels(), fields=dict(rule_labels()["fields"], total_max="3")),
                                        ["fields", "total_max"])),
        ("bounded-maximum", rule_field(lambda: rule_bounded(unit_tag("Text")), ["fields", "maximum"])),
        ("absolute-uri-max-bytes", rule_field(lambda: record_tag("AbsoluteUri", max_bytes="10"), ["fields", "max_bytes"])),
        ("timestamp-minimum-year", rule_field(rule_timestamp, ["value", "minimum_year"])),
        ("timestamp-maximum-year", rule_field(rule_timestamp, ["value", "maximum_year"])),
        ("dfa-state-count", rule_field(rule_dfa, ["value", "state_count"])),
        ("dfa-initial-state", rule_field(rule_dfa, ["value", "initial_state"])),
        ("dfa-accepting-state", rule_field(rule_dfa, ["value", "accepting_states", 0])),
        ("dfa-transition-from-state", rule_field(rule_dfa, ["value", "transitions", 0, "from_state"])),
        ("dfa-transition-first", rule_field(rule_dfa, ["value", "transitions", 0, "first"])),
        ("dfa-transition-last", rule_field(rule_dfa, ["value", "transitions", 0, "last"])),
        ("dfa-transition-to-state", rule_field(rule_dfa, ["value", "transitions", 0, "to_state"])),
        ("grapheme-property-first", profile_field(graphemes, ["grapheme_rules", "properties", 0, "first"])),
        ("grapheme-property-last", profile_field(graphemes, ["grapheme_rules", "properties", 0, "last"])),
        ("extended-pictographic-first", profile_field(graphemes, ["grapheme_rules", "extended_pictographic", 0, "first"])),
        ("extended-pictographic-last", profile_field(graphemes, ["grapheme_rules", "extended_pictographic", 0, "last"])),
        ("indic-conjunct-first", profile_field(graphemes, ["grapheme_rules", "indic_conjunct", 0, "first"])),
        ("indic-conjunct-last", profile_field(graphemes, ["grapheme_rules", "indic_conjunct", 0, "last"])),
    ]
    for name, change in fields:
        natural(f"{name}-negative", change, "-1")
    for name, change in fields[:12] + fields[18:22]:
        natural(f"{name}-leading-zero", change, "01")
        natural(f"{name}-number", change, 1)
    for name, change in fields[:6]:
        natural(f"{name}-plus-sign", change, "+1")
        natural(f"{name}-empty", change, "")
        natural(f"{name}-fraction", change, "1.5")


REJECTED_WHOLE = ("lone-surrogate-key-at-the-end", "duplicate-key-at-the-end", "exponent-at-the-end")


def json_stage_exponent_members() -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    zeros = "0" * 5000
    digits = "7" * 5000
    rejected = [
        ("exponent-negative-large", '"x":1e-99999999999,'),
        ("exponent-negative-at-the-limit", '"x":1e-10000,'),
        ("exponent-negative-at-the-limit-uppercase", '"x":1E-10000,'),
        ("exponent-negative-2-pow-32", '"x":1e-4294967296,'),
        ("exponent-positive-20-digits", '"x":1e99999999999999999999,'),
        ("exponent-negative-20-digits", '"x":1e-99999999999999999999,'),
        ("exponent-positive-leading-zeros-at-the-limit", '"x":1e000010000,'),
        ("exponent-positive-5000-leading-zeros-at-the-limit", f'"x":1e{zeros}10000,'),
        ("exponent-positive-with-plus-5000-leading-zeros-at-the-limit", f'"x":1e+{zeros}10000,'),
        ("exponent-negative-5000-leading-zeros-at-the-limit", f'"x":1e-{zeros}10000,'),
        ("exponent-negative-5000-digits-of-nonzero", f'"x":1e-{digits},'),
        ("exponent-negative-5000-digit-mantissa-at-the-limit", f'"x":{digits}e-10000,'),
    ]
    controls = [
        ("exponent-negative-below-the-limit", '"x":1e-9999,'),
        ("exponent-positive-leading-zeros-below-the-limit", '"x":1e00009999,'),
        ("exponent-positive-5000-leading-zeros-below-the-limit", f'"x":1e{zeros}5,'),
        ("exponent-positive-with-plus-5000-leading-zeros-below-the-limit", f'"x":1e+{zeros}5,'),
        ("exponent-positive-5000-leading-zeros-9999", f'"x":1e{zeros}9999,'),
        ("exponent-negative-5000-leading-zeros-below-the-limit", f'"x":1e-{zeros}5,'),
        ("exponent-negative-5000-leading-zeros-9999", f'"x":1e-{zeros}9999,'),
        ("exponent-negative-leading-zeros-small", '"x":1e-0000000005,'),
        ("exponent-zero-5000-leading-zeros", f'"x":1e-{zeros},'),
        ("mantissa-5000-digits", f'"x":{digits},'),
        ("mantissa-5000-fraction-digits", f'"x":0.{digits},'),
        ("mantissa-5000-digits-with-exponent-below-the-limit", f'"x":{digits}e9999,'),
        ("mantissa-5000-digits-with-negative-exponent-below-the-limit", f'"x":{digits}e-9999,'),
    ]
    return rejected, controls


def add_json_stage_cases(builder, plain, composition, expected_plain, expected_composition) -> None:
    label = "json-stage"

    def compact_text(exchange) -> str:
        return json.dumps(exchange, separators=(",", ":"), ensure_ascii=False)

    plain_text = compact_text(plain)
    composition_text = compact_text(composition)
    positions = (
        ("top-level", plain_text, '{', expected_plain),
        ("library", plain_text, '"signatures":{', expected_plain),
        ("composition", composition_text, '"composition":{', expected_composition),
    )
    for text, opener in ((plain_text, '{'), (plain_text, '"signatures":{'), (composition_text, '"composition":{')):
        if opener not in text or not text.endswith("]}"):
            raise RuntimeError(f"the exchange text does not have the shape that the JSON stage inputs assume: {opener}")

    rejected = [
        ("duplicate-key", '"x":1,"x":2,'),
        ("duplicate-key-with-escape", '"x":1,"\\u0078":2,'),
        ("duplicate-key-with-different-values", '"x":"a","x":null,'),
        ("duplicate-key-escape-first", '"\\u0078":1,"x":2,'),
        ("duplicate-key-both-escaped", '"\\u0078":1,"\\u0078":2,'),
        ("nested-duplicate-key-with-escape", '"x":{"y":1,"\\u0079":2},'),
        ("nested-duplicate-key-escape-first", '"x":{"\\u0079":1,"y":2},'),
        ("array-nested-duplicate-key-with-escape", '"x":[{"y":1,"\\u0079":2}],'),
        ("lone-high-surrogate", '"x":"\\ud800",'),
        ("lone-low-surrogate", '"x":"\\udc00",'),
        ("lone-surrogate-in-key", '"\\ud800":1,'),
        ("high-surrogate-then-ascii-escape", '"x":"\\ud800\\u0041",'),
        ("high-surrogate-then-high-surrogate", '"x":"\\ud800\\ud800",'),
        ("high-surrogate-then-plain-text", '"x":"\\ud800a",'),
        ("low-surrogate-then-high-surrogate", '"x":"\\udc00\\ud800",'),
        ("exponent-too-large", '"x":1e99999999999,'),
        ("exponent-too-large-uppercase", '"x":1E99999999999,'),
        ("exponent-too-large-with-plus", '"x":1e+99999999999,'),
        ("exponent-at-the-limit", '"x":1e10000,'),
        ("exponent-at-the-limit-with-plus", '"x":1E+10000,'),
        ("exponent-100000", '"x":1e100000,'),
        ("exponent-2-pow-32", '"x":1e4294967296,'),
        ("exponent-2-pow-32-minus-1", '"x":1e4294967295,'),
    ]
    exponent_rejected, exponent_controls = json_stage_exponent_members()
    rejected += exponent_rejected
    for position, text, opener, expected in positions:
        for name, member in rejected:
            builder.add(f"{label}/{position}-{name}", request_text(text.replace(opener, opener + member, 1), expected),
                        {label}, [check_reason("decode", "exchange_json")])

    controls = [
        ("valid-surrogate-pair", '"x":"\\ud83d\\ude00",'),
        ("surrogate-escape-in-uppercase-hex", '"x":"\\uD83D\\uDE00",'),
        ("exponent-below-the-limit", '"x":1e9999,'),
        ("exponent-400", '"x":1e400,'),
        ("exponent-plain", '"x":1.5e3,'),
        ("exponent-large-inside-string", '"x":"1e99999999999",'),
        ("lone-surrogate-text-inside-string-without-escape", '"x":"ud800",'),
        ("escaped-backslash-before-surrogate-text", '"x":"\\\\ud800",'),
        ("escaped-quote-before-exponent-text", '"x":"\\"1e99999999999",'),
        ("nan", '"x":NaN,'),
        ("infinity", '"x":Infinity,'),
        ("negative-infinity", '"x":-Infinity,'),
        ("raw-newline-in-string", '"x":"a\nb",'),
        ("raw-tab-in-string", '"x":"a\tb",'),
        ("raw-control-in-string", '"x":"a\u0001b",'),
        ("escaped-newline-in-string", '"x":"a\\nb",'),
        ("invalid-escape", '"x":"\\q",'),
        ("short-unicode-escape", '"x":"\\u12",'),
        ("non-hex-unicode-escape", '"x":"\\u12g4",'),
        ("leading-zero-number", '"x":01,'),
        ("bare-minus", '"x":-,'),
        ("trailing-dot-number", '"x":1.,'),
        ("leading-dot-number", '"x":.5,'),
        ("plus-sign-number", '"x":+1,'),
        ("single-quoted-string", "'x':1,"),
        ("unquoted-key", 'x:1,'),
        ("comment", '/*c*/"x":1,'),
        ("missing-comma", '"x":1 "y":2,'),
        ("missing-colon", '"x" 1,'),
        ("empty-key", '"":1,'),
        ("nested-duplicate-key", '"x":{"y":1,"y":2},'),
        ("array-with-nested-duplicate-key", '"x":[{"y":1,"y":2}],'),
    ]
    controls += exponent_controls
    for position, text, opener, expected in positions:
        for name, member in controls:
            builder.add(f"{label}/{position}-{name}", request_text(text.replace(opener, opener + member, 1), expected),
                        {label}, [])

    for position, text, expected in (("plain", plain_text, expected_plain),
                                     ("composition", composition_text, expected_composition)):
        whole = [
            ("trailing-comma-object", text[:-1] + ",}"),
            ("trailing-comma-array", text[:-2] + ",]}"),
            ("trailing-garbage", text + "x"),
            ("trailing-second-value", text + "{}"),
            ("trailing-newline", text + "\n"),
            ("trailing-spaces", text + "   "),
            ("leading-spaces", "   " + text),
            ("byte-order-mark", "\ufeff" + text),
            ("leading-comma", "," + text),
            ("empty-object", "{}"),
            ("empty-text", ""),
            ("whitespace-only", "   "),
            ("array-root", "[" + text + "]"),
            ("null-root", "null"),
            ("string-root", '"x"'),
            ("truncated", text[:-1]),
            ("doubled-root", text + text),
            ("lone-surrogate-key-at-the-end", text[:-1] + ',"\\ud800":1}'),
            ("duplicate-key-at-the-end", text[:-1] + ',"schema":"x"}'),
            ("exponent-at-the-end", text[:-1] + ',"x":1e99999999999}'),
        ]
        for name, body in whole:
            checks = [check_reason("decode", "exchange_json")] if name in REJECTED_WHOLE else []
            builder.add(f"{label}/{position}-{name}", request_text(body, expected), {label}, checks)


def full_kind_library(plain_library):
    library = rich_library(plain_library)
    profile = library["profile"]
    profile["bytes_policy"] = bytes_policy(wrapper="bytewrap")
    profile["grapheme_rules"] = grapheme_rules(
        properties=[{"first": "5", "last": "10", "property": unit_tag("Other")}],
        extended_pictographic=[{"first": "5", "last": "10"}],
        indic_conjunct=[{"first": "5", "last": "10", "property": unit_tag("Linker")}])
    profile["format_bindings"] += [
        binding("dfa", rule_dfa()), binding("stamp", rule_timestamp()), binding("dotted", rule_labels()),
        binding("seq", rule_sequence(unit_tag("Text"), rule_optional(unit_tag("Text")))),
        binding("alt", rule_choice(unit_tag("Text"), rule_not(unit_tag("Text")))),
        binding("capped", rule_bounded(unit_tag("Text"))),
        binding("uri", record_tag("AbsoluteUri", max_bytes="10"))]
    library["nodes"] += [
        integer_node("count", domain="integer", minimum="1", maximum="9", enum_values=["1", "2"],
                     default_value="1"),
        decimal_node("amount", decimal_bound("1", "2"), decimal_bound("5", "2", True)),
        string_node("labelled", format=named("tagname"), lengths=[length_bound("1", "8"),
                                                                  length_bound("1", "4", "Graphemes")],
                    wrapper="textwrap", enum_values=["abc", "def"], examples=["abc"], default_value="abc"),
        string_node("inlined", format=inline(rule_sequence(unit_tag("Text"), rule_optional(unit_tag("Text"))))),
        bytes_node("blob", "1", "8"),
        array_node("list", "truth", "1", "3"),
        product_node("pair2", [("first", "truth"), ("second", "unit")]),
        extras_node("bag", named("tagname")),
        node("never", unit_tag("Never")),
        alias_node("alias", "truth"),
        node("raw", record_tag("RawBody", encoding="utf-8")),
        node("opaque", record_tag("Opaque", type_name="Opaque")),
        node("unknown-any", tuple_tag("Unknown", unit_tag("Any"))),
        node("unknown-object", tuple_tag("Unknown", unit_tag("OrdinaryObject"))),
        union_node("kinds", [branch("truth", "kt", kind_selector("Boolean")),
                             branch("unit", "kn", kind_selector("Null")),
                             branch("pair2", "kp", member_shape(("first", ABSENT))),
                             branch("bag", "kb", OTHERWISE)]),
    ]
    library["definitions"] += [
        {"id": "symbolic", "wire_identity": "Symbolic", "shape": tuple_tag("Symbol", "symbolic")},
        {"id": "message", "wire_identity": "Message", "shape": tuple_tag("Message", "truth")},
    ]
    library["provenance"].extend([
        provenance_binding(unit_tag("Library"), origin()),
        provenance_binding(target_group("document"), origin()),
        provenance_binding(target_definition("operation"), origin()),
        provenance_binding(target_type("truth"), origin()),
        provenance_binding(target_outcome("operation", "success"), origin())])
    library["annotations"].extend([
        annotation(unit_tag("Library")), annotation(target_group("document")),
        annotation(target_definition("value")), annotation(target_type("unit")),
        annotation(target_outcome("operation", "refused"))])
    return library


FULL_LIBRARY_ENTRYPOINTS = (("example", "value"), ("operation", "operation"), ("symbolic", "symbolic"),
                            ("message", "message"))


def assemble_exchange(cargo: str, library, entrypoints) -> dict:
    argv = [cargo, "run", "--quiet", "--locked", "--manifest-path", str(GENERATOR_MANIFEST), "--bin",
            "rust_generation_envelope"]
    request = compact({"library": library, "entrypoints": [
        {"identity": identity, "definition": definition} for identity, definition in entrypoints]})
    proc = subprocess.run(argv, input=request + "\n", capture_output=True, text=True, cwd=ROOT,
                          timeout=TIMEOUT_SECONDS, check=False)
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or len(lines) != 1 or "exchange" not in json.loads(lines[0]):
        raise SystemExit(f"the exchange envelope failed: {proc.stderr[-400:]} {proc.stdout[-400:]}")
    return json.loads(json.loads(lines[0])["exchange"])


def read_example(name: str) -> tuple[dict, dict]:
    document = json.loads((ENTRY_DIR / "examples" / f"{name}.request.json").read_text(encoding="utf-8"))
    return json.loads(document["exchange"]), document["expected_basis"]["basis"]


def exhaustive_bases(cargo: str, plain_text: str, composition_text: str) -> list[tuple[str, dict, dict]]:
    plain = json.loads(plain_text)
    composition = json.loads(composition_text)
    rich = assemble_exchange(cargo, full_kind_library(plain["signatures"]), FULL_LIBRARY_ENTRYPOINTS)
    unique, unique_basis = read_example("accepted-unique")
    closure, closure_basis = read_example("rejected-closure-used-site")
    return [("accepted", plain, plain["basis"]), ("accepted-rich-library", rich, rich["basis"]),
            ("accepted-composition", composition, composition["basis"]),
            ("accepted-unique", unique, unique_basis), ("rejected-closure-used-site", closure, closure_basis)]


def add_exhaustive_cases(builder: Builder, bases: list[tuple[str, dict, dict]]) -> None:
    seen: set[tuple] = set()
    for name, exchange, expected in bases:
        check = (check_derivation_verified(check_kind("composition")) if name.startswith("rejected")
                 else check_accepted())
        builder.add(f"exhaustive/{name}/base", request_text(exchange, expected),
                    {"exhaustive-base", f"exhaustive-from-{name}"}, [check])
        for item in exhaustive.exhaustive_inputs(name, exchange, expected, seen):
            state = "recomputed" if item.recomputed else "stale"
            builder.add_mutation(item, {f"exhaustive-{item.mutation.family}", f"exhaustive-{state}",
                                        f"exhaustive-from-{name}"})



def generate(cargo: str, extra: list[str]) -> str:
    argv = [cargo, "run", "--quiet", "--locked", "--manifest-path", str(GENERATOR_MANIFEST), "--bin", "signatures"]
    argv += extra
    proc = subprocess.run(argv, capture_output=True, text=True, cwd=ROOT, timeout=TIMEOUT_SECONDS, check=False)
    if proc.returncode != 0:
        raise SystemExit(f"signature generator failed ({' '.join(extra) or 'plain'}): {proc.stderr[-800:]}")
    return proc.stdout.strip()


def which(name: str) -> str:
    found = shutil.which(name)
    if found is None:
        raise Missing(f"executable not found: {name}")
    return found


def prepare_lean(args, work: Path) -> Runner:
    binary = ENTRY_DIR / ".lake" / "build" / "bin" / "signature_admission"
    if not binary.is_file():
        raise Missing(f"Lean entry is not built: {binary} (run `lake build` in {ENTRY_DIR})")
    return Runner([str(binary)], ENTRY_DIR, dict(os.environ))


def prepare_python(args, work: Path) -> Runner:
    env = dict(os.environ)
    existing = [env["PYTHONPATH"]] if env.get("PYTHONPATH") else []
    env["PYTHONPATH"] = os.pathsep.join([str(ROOT / "packages/python/adapter" / "src")] + existing)
    probe = subprocess.run([args.python, "-c", "import neco_quotient_certificate, necoherence.type_signatures"],
                           capture_output=True, text=True, env=env, check=False)
    if probe.returncode != 0:
        raise Missing(f"{args.python} cannot import neco_quotient_certificate and necoherence: {probe.stderr[-300:]}")
    return Runner([args.python, str(ENTRY_DIR / "python_entry.py")], ENTRY_DIR, env)


def prepare_typescript(args, work: Path) -> Runner:
    for dist in (ROOT / "packages/typescript/adapter" / "dist" / "index.js",):
        if not dist.is_file():
            raise Missing(f"TypeScript dist is not built: {dist} (run `npm ci` and `npm run build`)")
    return Runner([which("node"), str(ENTRY_DIR / "typescript.mjs")], ENTRY_DIR, dict(os.environ))


def prepare_java(args, work: Path) -> Runner:
    entry = ENTRY_DIR / "java" / "SignatureAdmission.java"
    if not entry.is_file():
        raise Missing(f"Java entry is not merged: {entry}")
    jars = sorted(glob.glob(args.java_jar or str(ROOT / "packages/java/adapter" / "build" / "necoherence-*.jar")))
    if not jars:
        raise Missing("Java jar is not built: packages/java/adapter/build/necoherence-*.jar (run packages/java/build-maven.sh)")
    classes = work / "java-classes"
    classes.mkdir(parents=True, exist_ok=True)
    sourcepath = os.pathsep.join((os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"]))
    proc = subprocess.run([which("javac"), "-cp", jars[-1], "-sourcepath", sourcepath, "-d", str(classes), str(entry)],
                          capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise Missing(f"Java entry does not compile: {proc.stderr[-300:]}")
    return Runner([which("java"), "-cp", f"{classes}{os.pathsep}{jars[-1]}", "SignatureAdmission"],
                  ENTRY_DIR, dict(os.environ))


def prepare_rust(args, work: Path) -> Runner:
    source = ROOT / "verification" / "declaration" / "signature_generator" / "src" / "bin" / \
        "signature_admission_outcome.rs"
    if not source.is_file():
        raise Missing(f"Rust entry is not merged: {source}")
    argv = [which("cargo"), "run", "--quiet", "--locked", "--manifest-path", str(GENERATOR_MANIFEST),
            "--bin", "signature_admission_outcome", "--"]
    return Runner(argv, ROOT, dict(os.environ))


def prepare_gleam(args, work: Path) -> Runner:
    gleam_dir = ENTRY_DIR / "gleam"
    if not (gleam_dir / "gleam.toml").is_file():
        raise Missing(f"Gleam entry is not merged: {gleam_dir}")
    return Runner([which("gleam"), "run", "--no-print-progress", "--"], gleam_dir, dict(os.environ))


PREPARE = {
    "lean": prepare_lean,
    "python": prepare_python,
    "typescript": prepare_typescript,
    "java": prepare_java,
    "rust": prepare_rust,
    "gleam": prepare_gleam,
}


BATCH_FLAG = "--batch"
BATCH_TIMEOUT_SECONDS = 3600
SHARD_MINIMUM = 2000


def is_error_line(value) -> bool:
    return isinstance(value, dict) and "result" not in value and "error" in value


def run_batch_once(runner: Runner, cases: list[Case]) -> tuple[list[dict], str | None]:
    proc = subprocess.Popen(runner.argv + [BATCH_FLAG], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=runner.cwd, env=runner.env)
    stderr_tail = bytearray()

    def feed() -> None:
        try:
            for case in cases:
                text = case.text()
                if "\n" in text:
                    raise RuntimeError(f"a request has a raw newline: {case.name}")
                proc.stdin.write(text.encode("utf-8") + b"\n")
            proc.stdin.close()
        except BrokenPipeError:
            pass

    def drain() -> None:
        for chunk in iter(lambda: proc.stderr.read(4096), b""):
            stderr_tail.extend(chunk)
            del stderr_tail[:-2000]

    threads = [threading.Thread(target=feed, daemon=True), threading.Thread(target=drain, daemon=True)]
    for thread in threads:
        thread.start()
    results: list[dict] = []
    for raw in proc.stdout:
        try:
            results.append(json.loads(raw.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError):
            results.append({"error": f"unreadable output line: {raw[:200]!r}"})
    code = proc.wait(timeout=BATCH_TIMEOUT_SECONDS)
    for thread in threads:
        thread.join()
    failure = None
    if len(results) < len(cases):
        failure = f"exit {code} after {len(results)} outputs: {bytes(stderr_tail).decode('utf-8', 'replace')[-400:]}"
    return results[:len(cases)], failure


def run_batch(runner: Runner, cases: list[Case]) -> tuple[dict[str, dict], dict[str, str]]:
    outputs: dict[str, dict] = {}
    errors: dict[str, str] = {}
    position = 0
    while position < len(cases):
        pending = cases[position:]
        results, failure = run_batch_once(runner, pending)
        for case, result in zip(pending, results):
            if is_error_line(result):
                errors[case.name] = str(result["error"])
            else:
                outputs[case.name] = result
        position += len(results)
        if failure is not None:
            errors[cases[position].name] = failure
            position += 1
    return outputs, errors


def run_language(runner: Runner, cases: list[Case], shards: int) -> tuple[dict[str, dict], dict[str, str], float]:
    started = time.monotonic()
    count = max(1, min(shards, len(cases) // SHARD_MINIMUM))
    size = -(-len(cases) // count)
    pieces = [cases[start:start + size] for start in range(0, len(cases), size)]
    if len(pieces) == 1:
        results = [run_batch(runner, pieces[0])]
    else:
        with ThreadPoolExecutor(max_workers=len(pieces)) as pool:
            results = list(pool.map(lambda piece: run_batch(runner, piece), pieces))
    outputs: dict[str, dict] = {}
    errors: dict[str, str] = {}
    for piece_outputs, piece_errors in results:
        outputs.update(piece_outputs)
        errors.update(piece_errors)
    return outputs, errors, time.monotonic() - started


def failure_key(output: dict) -> str:
    output = output.get("admission", output)
    if output.get("result") == "accepted":
        return "accepted"
    failure = failure_of(output)
    kind = failure.get("kind", "?")
    return kind if "reason" not in failure else f"{kind}:{failure['reason']}"


def diff_paths(left, right, path: str = "$"):
    if type(left) is not type(right) or not isinstance(left, (dict, list)):
        if left != right:
            yield path, left, right
        return
    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            child = f"{path}.{key}"
            if key not in left:
                yield child, "<missing>", right[key]
            elif key not in right:
                yield child, left[key], "<missing>"
            else:
                yield from diff_paths(left[key], right[key], child)
        return
    if len(left) != len(right):
        yield f"{path}.length", len(left), len(right)
    for index, (a, b) in enumerate(zip(left, right)):
        yield from diff_paths(a, b, f"{path}[{index}]")


def case_group(case: Case) -> tuple[str, str]:
    if case.mutation is None:
        return case.name.split("/")[0], "-"
    return case.mutation.mutation.family, case.mutation.mutation.shape


def diff_record(language: str, case: Case, reference: dict | None, actual: dict | None, note: str | None) -> dict:
    mutation = case.mutation.mutation if case.mutation is not None else None
    return {"language": language, "name": case.name, "labels": sorted(case.labels),
            "base": case.mutation.base if case.mutation is not None else None,
            "family": mutation.family if mutation is not None else None,
            "shape": mutation.shape if mutation is not None else None,
            "path": mutation.position if mutation is not None else None,
            "mutation": mutation.description if mutation is not None else None,
            "recomputed": case.mutation.recomputed if case.mutation is not None else None,
            "lean": reference, "actual": actual, "note": note}


def summary_table(records: list[dict]) -> list[str]:
    rows: dict[tuple, list] = {}
    for record in records:
        lean_key = failure_key(record["lean"]) if record["lean"] is not None else "<none>"
        actual_key = failure_key(record["actual"]) if record["actual"] is not None else "<error>"
        key = (record["language"], record["family"] or "existing", record["shape"] or "-", lean_key, actual_key)
        row = rows.setdefault(key, [0, record["name"]])
        row[0] += 1
    lines = ["count\tlanguage\tfamily\tposition shape\tlean\tlanguage output\texample"]
    for key, (count, example) in sorted(rows.items(), key=lambda item: (item[0][0], -item[1][0], item[0][1:])):
        lines.append(f"{count}\t" + "\t".join(key) + f"\t{example}")
    return lines


def propagation_case(case: Case) -> Case | None:
    try:
        request = json.loads(case.text())
    except ValueError:
        return None
    if not isinstance(request, dict) or not isinstance(request.get("exchange"), str) or "expected_basis" not in request:
        return None
    request["mode"] = "propagation"
    checks = [getattr(check, "propagation", check) for check in case.checks]
    admission_checks = list(case.checks) if any(hasattr(check, "propagation") for check in case.checks) else None
    return dataclasses.replace(case, request=compact(request), packed=None, checks=checks,
                               admission_checks=admission_checks)


def boundary_view(output: dict, mode: str) -> dict:
    return output["admission"] if mode == "propagation" and "admission" in output else output


def shared_boundaries(reference: dict, actual: dict) -> tuple[dict, dict]:
    if not (isinstance(reference, dict) and isinstance(actual, dict)
            and isinstance(reference.get("boundaries"), dict) and isinstance(actual.get("boundaries"), dict)):
        return reference, actual
    names = set(reference["boundaries"]) & set(actual["boundaries"])
    return ({**reference, "boundaries": {k: v for k, v in reference["boundaries"].items() if k in names}},
            {**actual, "boundaries": {k: v for k, v in actual["boundaries"].items() if k in names}})


def boundary_expectation(output: dict) -> str | None:
    if "admission" not in output and failure_of(output).get("kind") == "request":
        return None
    boundaries = output.get("boundaries")
    admission = output.get("admission")
    if not isinstance(boundaries, dict) or not isinstance(admission, dict):
        return f"propagation output without admission and boundaries: {short(output)}"
    if admission.get("result") == "accepted":
        expected = {"result": "accepted"}
    else:
        expected = {"result": "failed", "failure": admission.get("failure")}
    if "generator" not in boundaries:
        return f"propagation output without the generator boundary: {short(output)}"
    for name, boundary in boundaries.items():
        if boundary != expected:
            return f"{name} boundary {short(boundary)} differs from the admission {short(expected)}"
    return None


def split_difference(reference: dict, actual: dict, generator_checks) -> str | None:
    def without_generator(output: dict) -> dict:
        boundaries = output.get("boundaries")
        if not isinstance(boundaries, dict):
            return output
        return {**output, "boundaries": {k: v for k, v in boundaries.items() if k != "generator"}}

    if "generator" not in actual["boundaries"]:
        return f"propagation output without the generator boundary: {short(actual)}"
    left, right = shared_boundaries(without_generator(reference), without_generator(actual))
    if canonical(left) != canonical(right):
        return "admission or generation boundary differs from lean"
    generator = actual["boundaries"]["generator"]
    messages = [message for message in (check(generator, {}) for check in generator_checks) if message is not None]
    if messages:
        return "generator boundary against the admission expectation: " + "; ".join(messages)
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compare the admission entries of the six languages with Lean.")
    parser.add_argument("--languages", default=",".join(LANGUAGES),
                        help="comma-separated subset of: " + ",".join(LANGUAGES) + " (default: all six)")
    parser.add_argument("--cases", default="existing", choices=("existing", "exhaustive", "all"),
                        help="the inputs to run: the written ones, the mutation ones, or both (default: existing)")
    parser.add_argument("--python", default=sys.executable, help="interpreter for the Python entry")
    parser.add_argument("--java-jar", default=None, help="glob of the necoherence jar for the Java entry")
    parser.add_argument("--stride", type=int, default=1,
                        help="run every Nth mutation input in the deterministic order (default: 1, every input)")
    parser.add_argument("--jobs", type=int, default=1, help="number of languages that run at the same time")
    parser.add_argument("--shards", type=int, default=1,
                        help="number of batch processes per language (each runs at least %d requests)" % SHARD_MINIMUM)
    parser.add_argument("--diff-log", default=None,
                        help="file for every difference as one JSON line (the summary table goes to <file>.summary)")
    parser.add_argument("--mode", default="admission", choices=("admission", "propagation"),
                        help="admission: the runtime admission entries on every input (default); propagation: the "
                             "inputs with the propagation label, through the generator boundary of lean and rust")
    parser.add_argument("--work", default=None,
                        help="scratch directory for the requests and outputs (default: a temporary directory removed at exit)")
    args = parser.parse_args(argv)

    selected = [name.strip() for name in args.languages.split(",") if name.strip()]
    unknown = [name for name in selected if name not in LANGUAGES]
    if unknown:
        print(f"unknown languages: {unknown}", file=sys.stderr)
        return 2
    if args.mode == "propagation":
        skipped = [name for name in selected if name not in PROPAGATION_LANGUAGES]
        selected = [name for name in selected if name in PROPAGATION_LANGUAGES]
        if skipped:
            print(f"propagation compares the generator boundary of lean and rust only; not run: {skipped}")
    needed = ["lean"] + [name for name in dict.fromkeys(selected) if name != "lean"]
    if args.work is None:
        work = Path(tempfile.mkdtemp(prefix="signature-admission-compare-"))
        atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))
    else:
        work = Path(args.work).resolve()
    work.mkdir(parents=True, exist_ok=True)

    runners: dict[str, Runner] = {}
    missing: list[str] = []
    for name in needed:
        try:
            runners[name] = PREPARE[name](args, work)
        except Missing as error:
            missing.append(f"{name}: {error}")
    if missing:
        print("entries are not ready:", file=sys.stderr)
        for line in missing:
            print("  " + line, file=sys.stderr)
        return 2

    cargo = which("cargo")
    plain_text = generate(cargo, [])
    composition_text = generate(cargo, ["--", "composition"])
    builder = Builder()
    if args.cases in ("existing", "all"):
        build_cases(plain_text, composition_text, builder)
    if args.cases in ("exhaustive", "all"):
        add_exhaustive_cases(builder, exhaustive_bases(cargo, plain_text, composition_text))
    cases = builder.cases
    if args.stride > 1:
        position = -1
        kept = []
        for case in cases:
            if case.mutation is not None:
                position += 1
                if position % args.stride:
                    continue
            kept.append(case)
        cases = kept
    if args.mode == "propagation":
        cases = [mapped for mapped in (propagation_case(case) for case in cases if "propagation" in case.labels)
                 if mapped is not None]
    (work / "cases").mkdir(exist_ok=True)
    for index, case in enumerate(cases):
        if case.mutation is None:
            (work / "cases" / f"{index:03d}.request.json").write_text(case.request + "\n", encoding="utf-8")

    outputs: dict[str, dict[str, dict]] = {}
    errors: dict[str, dict[str, str]] = {}
    seconds: dict[str, float] = {}

    def run_one(name: str) -> None:
        outputs[name], errors[name], seconds[name] = run_language(runners[name], cases, args.shards)

    if args.jobs > 1:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            list(pool.map(run_one, needed))
    else:
        for name in needed:
            run_one(name)

    lean_outputs = outputs["lean"]
    lean_view = {name: boundary_view(output, args.mode) for name, output in lean_outputs.items()}
    expectation_failures: list[str] = []
    for case in cases:
        if case.name not in lean_outputs:
            continue
        for check in case.checks:
            message = check(lean_view[case.name], lean_view)
            if message is not None:
                expectation_failures.append(f"{case.name}: {message}")
        if args.mode == "propagation":
            message = boundary_expectation(lean_outputs[case.name])
            if message is not None:
                expectation_failures.append(f"{case.name}: {message}")

    records: list[dict] = []
    differences = {name: 0 for name in selected if name != "lean"}
    for name in differences:
        for case in cases:
            if case.name in errors[name]:
                differences[name] += 1
                records.append(diff_record(name, case, lean_outputs.get(case.name), None, errors[name][case.name]))
                continue
            if case.name in errors["lean"] or case.name not in lean_outputs:
                differences[name] += 1
                records.append(diff_record(name, case, None, outputs[name].get(case.name),
                                           "lean: " + str(errors["lean"].get(case.name))))
                continue
            reference = lean_outputs[case.name]
            actual = outputs[name][case.name]
            split = (args.mode == "propagation" and case.admission_checks is not None
                     and isinstance(actual.get("boundaries"), dict) and "admission" in actual)
            if split:
                message = split_difference(reference, actual, case.admission_checks)
                if message is not None:
                    differences[name] += 1
                    records.append(diff_record(name, case, reference, actual, "propagation: " + message))
                continue
            preservation = boundary_expectation(actual) if args.mode == "propagation" else None
            if preservation is not None:
                differences[name] += 1
                records.append(diff_record(name, case, reference, actual, "propagation: " + preservation))
            elif canonical(shared_boundaries(reference, actual)[0]) != canonical(shared_boundaries(reference, actual)[1]):
                differences[name] += 1
                records.append(diff_record(name, case, reference, actual, None))

    by_name = {case.name: case for case in cases}
    for record in records:
        case = by_name[record["name"]]
        if record["note"] is not None:
            print(f"ERROR {record['language']} {record['name']} labels={record['labels']}: {record['note']}")
            continue
        print(f"DIFF {record['language']} {record['name']} labels={record['labels']} "
              f"lean={failure_key(record['lean'])} {record['language']}={failure_key(record['actual'])}")
        if case.mutation is None:
            for path, left, right in diff_paths(record["lean"], record["actual"]):
                print(f"  {path}: lean={short(left, 160)} {record['language']}={short(right, 160)}")
            print(f"  lean: {canonical(record['lean'])}")
            print(f"  {record['language']}: {canonical(record['actual'])}")
    if args.diff_log is not None:
        with open(args.diff_log, "w", encoding="utf-8") as log:
            for record in records:
                log.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        Path(args.diff_log + ".summary").write_text("\n".join(summary_table(records)) + "\n", encoding="utf-8")

    label_counts: dict[str, int] = {}
    for case in cases:
        for label in case.labels:
            label_counts[label] = label_counts.get(label, 0) + 1
    print(f"mode: {args.mode}")
    print(f"inputs: {len(cases)} unique requests; requests per label:")
    for label in sorted(label_counts):
        print(f"  {label}: {label_counts[label]}")
    accepted = sum(1 for case in cases if lean_view.get(case.name, {}).get("result") == "accepted")
    print(f"lean results: accepted={accepted} failed={len(lean_outputs) - accepted} errors={len(errors['lean'])}")
    for name, count in differences.items():
        print(f"language {name}: compared={len(cases)} differences={count} errors={len(errors[name])}")
    for name in needed:
        print(f"batch seconds {name}: {seconds[name]:.1f}")
    print("lean stage distribution (group, digests, stage: count):")
    stages: dict[tuple[str, str, str], int] = {}
    for case in cases:
        if case.name not in lean_outputs:
            continue
        if case.mutation is None:
            group = "existing"
        else:
            tokens = case.mutation.mutation.shape.split(".")
            region = ".".join(tokens[:3] if tokens[:2] == ["$", "composition"] else tokens[:2])
            group = f"{case.mutation.mutation.family} {region.split('[')[0]}"
        digests = ("recomputed" if case.mutation.recomputed else "stale") if case.mutation is not None else "-"
        output = lean_view[case.name]
        stage = "accepted" if output.get("result") == "accepted" else failure_of(output).get("kind", "?")
        stages[(group, digests, stage)] = stages.get((group, digests, stage), 0) + 1
    for (group, digests, stage), count in sorted(stages.items()):
        print(f"  {group}\t{digests}\t{stage}\t{count}")
    print("difference table:")
    for line in summary_table(records):
        print("  " + line)
    print(f"expectation failures: {len(expectation_failures)}")
    for message in expectation_failures:
        print(f"  EXPECTATION {message}")
    total = sum(differences.values()) + len(expectation_failures) + len(errors["lean"])
    print(f"total failures: {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
