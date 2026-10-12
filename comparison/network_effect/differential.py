# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Invocation-time normalized Differential for the Lean and runtime runners."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .generator import (
    conflicting_delivery,
    effect_observation,
    finite_domains,
    generate_clock_invocations,
    generate_field_mutations,
    generate_invocations,
    generate_malformed_invocations,
    generate_model_cases,
    generate_observation_invocations,
    generate_observation_mutations,
    generate_race_cases,
    generate_race_observations,
    generate_response_cases,
    generate_timeout_observations,
    pairwise_coverage,
    response_pairwise_coverage,
    retry_request,
    stateful_seed_invocation,
)
from .mock_actions import run_race

ROOT = Path(__file__).resolve().parents[2]
LEAN_DIR = ROOT / "lean"


@dataclass(frozen=True)
class RunnerSpec:
    name: str
    command: tuple[str, ...]
    cwd: Path
    required: tuple[Path, ...] = ()
    prepare: tuple[str, ...] = ()
    prepare_cwd: Path | None = None
    artifact: str | None = None

@dataclass(frozen=True)
class RunnerObservation:
    lane: str
    available: bool
    observation: dict[str, Any]


def runner_specs() -> tuple[RunnerSpec, ...]:
    lean_binary = LEAN_DIR / ".lake" / "build" / "bin" / "network_effect_runner"
    if lean_binary.exists():
        lean_spec = RunnerSpec("lean", (str(lean_binary),), ROOT, (lean_binary,))
    else:
        lean_spec = RunnerSpec(
            "lean",
            ("lake", "exe", "network_effect_runner"),
            LEAN_DIR,
            (LEAN_DIR / "Necoherence/NetworkEffectRunner.lean",),
        )
    java_home = os.environ.get("JAVA_HOME")
    java = str(Path(java_home) / "bin/java") if java_home else "java"
    return (
        lean_spec,
        RunnerSpec("python", (sys.executable, "-m", "comparison.network_effect.run_python"), ROOT, (ROOT / "comparison/network_effect/run_python.py",)),
        RunnerSpec("rust", ("network_effect_compare",), ROOT / "rust", (ROOT / "rust/examples/network_effect_compare.rs",), ("cargo", "build", "--locked", "--example", "network_effect_compare", "--message-format=json"), ROOT / "rust", "network_effect_compare"),
        RunnerSpec("typescript", ("node", "dist/network-effect-runner.js"), ROOT / "typescript", (ROOT / "typescript/src/network-effect-runner.ts",), ("sh", "-c", "npm ci && npm run build"), ROOT / "typescript"),
        RunnerSpec("java", (java, "-cp", "build/classes", "necoherence.network.NetworkEffectRunner"), ROOT / "java", (ROOT / "java/src/main/java/necoherence/network/NetworkEffectRunner.java",), ("sh", "-c", "mkdir -p build/classes && find src/main/java -name '*.java' -exec javac --release 21 -d build/classes {} +"), ROOT / "java"),
        RunnerSpec("gleam", ("gleam", "run", "--no-print-progress", "-m", "necoherence/network_effect_runner"), ROOT / "gleam", (ROOT / "gleam/src/necoherence/network_effect.gleam",), ("gleam", "build"), ROOT / "gleam"),
    )


def normalize(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: normalize(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return [normalize(item) for item in value]
    return value

def comparable(value: dict[str, Any]) -> Any:
    if value.get("result") == "InvalidInvocation":
        return {"result": "InvalidInvocation"}
    return normalize(value)


def _unavailable(spec: RunnerSpec, reason: str, stderr: str = "") -> RunnerObservation:
    detail = reason if not stderr else reason + ";stderr:" + stderr[:400].replace("\n", "\\n")
    return RunnerObservation(spec.name, False, {"result": "LaneRunnerUnavailable", "lane": spec.name, "reason": detail})


def runner_environment(spec: RunnerSpec) -> dict[str, str]:
    environment = os.environ.copy()
    if spec.name == "java":
        java_home = environment.get("JAVA_HOME")
        if java_home:
            environment["PATH"] = str(Path(java_home) / "bin") + os.pathsep + environment.get("PATH", "")
    return environment


def _cargo_messages(stdout: str) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("stdout_path"), str):
            messages.extend(_cargo_messages(Path(value["stdout_path"]).read_text()))
        elif isinstance(value, dict):
            messages.append(value)
    return messages


def _artifact_executable(stdout: str, artifact: str) -> str | None:
    for message in _cargo_messages(stdout):
        if message.get("reason") == "compiler-artifact" and message.get("target", {}).get("name") == artifact and message.get("executable"):
            return str(message["executable"])
    return None


def prepare_runner(spec: RunnerSpec) -> tuple[RunnerSpec, RunnerObservation | None]:
    if not spec.prepare:
        return spec, None
    completed = subprocess.run(spec.prepare, cwd=spec.prepare_cwd or spec.cwd, text=True, capture_output=True, timeout=1800, check=False, env=runner_environment(spec))
    if completed.returncode:
        return spec, _unavailable(spec, f"PrepareExit:{completed.returncode}", completed.stderr)
    if spec.artifact is None:
        return spec, None
    executable = _artifact_executable(completed.stdout, spec.artifact)
    if executable is None:
        return spec, _unavailable(spec, "ArtifactUnavailable:" + spec.artifact, completed.stderr)
    return RunnerSpec(spec.name, (executable,), spec.cwd, spec.required), None


def invoke(spec: RunnerSpec, invocation: dict[str, Any], timeout: float = 30.0) -> RunnerObservation:
    missing = [str(path.relative_to(ROOT)) for path in spec.required if not path.exists()]
    if missing:
        return _unavailable(spec, "Missing:" + ",".join(missing))
    if shutil.which(spec.command[0]) is None:
        return _unavailable(spec, "ExecutableUnavailable:" + spec.command[0])
    try:
        completed = subprocess.run(
            spec.command,
            cwd=spec.cwd,
            input=json.dumps(invocation, separators=(",", ":")) + "\n",
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env={**runner_environment(spec), "PYTHONPATH": str(ROOT / "python" / "src") + os.pathsep + str(ROOT) + os.pathsep + os.environ.get("PYTHONPATH", "")},
        )
    except subprocess.TimeoutExpired as exc:
        detail = exc.stderr if isinstance(exc.stderr, str) else ""
        return _unavailable(spec, type(exc).__name__, detail)
    except OSError as exc:
        return _unavailable(spec, type(exc).__name__, str(exc))
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if completed.returncode != 0:
        return _unavailable(spec, f"Exit:{completed.returncode}", completed.stderr)
    if not lines:
        return _unavailable(spec, "EmptyStdout", completed.stderr)
    try:
        value = json.loads(lines[-1])
    except json.JSONDecodeError:
        return _unavailable(spec, "InvalidJson")
    if not isinstance(value, dict):
        return _unavailable(spec, "NonObjectJson")
    return RunnerObservation(spec.name, True, normalize(value))

def _reference_step(
    spec: RunnerSpec,
    invocation: dict[str, Any],
    expected_result: str,
) -> dict[str, Any]:
    result = invoke(spec, invocation)
    if not result.available:
        raise RuntimeError(f"Lean reference unavailable: {result.observation}")
    actual = result.observation.get("result")
    if actual != expected_result:
        raise RuntimeError(f"Lean reference returned {actual}, expected {expected_result}: {result.observation}")
    return result.observation


def _stateful_invocations(spec: RunnerSpec) -> list[tuple[str, dict[str, Any]]]:
    stages: list[tuple[str, dict[str, Any]]] = []

    seed = stateful_seed_invocation()
    prepared_result = _reference_step(spec, seed, "Prepared")
    prepared_state = prepared_result["state"]
    prepared = prepared_result["prepared"]
    stages.append(("stateful.prepare", seed))

    send = {"operation": "sendCommand", "state": prepared_state, "prepared": prepared}
    sent_result = _reference_step(spec, send, "CommandReady")
    command_state = sent_result["state"]
    stages.append(("stateful.sendCommand", send))

    handle = {"value": "generated-handle"}
    start = {
        "operation": "observeStart",
        "state": command_state,
        "prepared": prepared,
        "observation": {
            "tag": "Started",
            "attempt": prepared["input"]["attempt"],
            "handle": handle,
        },
    }
    started_result = _reference_step(spec, start, "Started")
    started_state = started_result["state"]
    started = started_result["started"]
    authoritative_handle = started["handle"]
    stages.append(("stateful.observeStart", start))

    stages.extend(
        (
            (
                "stateful.observe.pending",
                {
                    "operation": "observe",
                    "state": started_state,
                    "observation": {
                        "tag": "Pending",
                        "attempt": prepared["input"]["attempt"],
                        "handle": authoritative_handle,
                    },
                },
            ),
            (
                "stateful.cancelCommand",
                {"operation": "cancelCommand", "state": started_state, "started": started},
            ),
        )
    )

    for mutation in generate_field_mutations("prepared", prepared):
        stages.append(
            (
                "relation-mutation:sendCommand:" + mutation["field"],
                {
                    "operation": "sendCommand",
                    "state": prepared_state,
                    "prepared": mutation["value"],
                },
            )
        )
    for mutation in generate_field_mutations("started", started):
        stages.append(
            (
                "relation-mutation:cancelCommand:" + mutation["field"],
                {
                    "operation": "cancelCommand",
                    "state": started_state,
                    "started": mutation["value"],
                },
            )
        )
    for mutation in generate_observation_mutations(prepared, authoritative_handle):
        stages.append(
            (
                "relation-mutation:observe:" + mutation["field"],
                {
                    "operation": "observe",
                    "state": started_state,
                    "observation": mutation["value"],
                },
            )
        )

    for pair, observation in generate_timeout_observations(prepared, authoritative_handle):
        stages.append(
            (
                "timeout:" + pair["stage"] + ":" + pair["cause"],
                {
                    "operation": "observe",
                    "state": started_state,
                    "observation": observation,
                },
            )
        )
    matching_deadline = next(
        generate_race_observations(
            prepared,
            authoritative_handle,
            ("deadline",),
        )
    )
    stages.append(
        (
            "timeout:matching-clock-deadline",
            {
                "operation": "observe",
                "state": started_state,
                "observation": matching_deadline,
            },
        )
    )


    for race_case in generate_race_cases():
        order = race_case["order"]
        source_sequences = race_case["sourceSequences"]
        relation = race_case["relation"]
        race_state = started_state
        observations = generate_race_observations(
            prepared,
            authoritative_handle,
            order,
            source_sequences,
        )
        for delivery, observation in enumerate(observations):
            kind = order[delivery]
            invocation = {
                "operation": "observe",
                "state": race_state,
                "observation": observation,
            }
            expected = "Terminal" if delivery == 0 else "Late"
            race_result = _reference_step(spec, invocation, expected)
            stages.append(
                (
                    f"stateful-race:{relation}:{order[0]}-first:{delivery}:{kind}",
                    invocation,
                )
            )
            race_state = race_result["state"]

    response = next(
        generate_race_observations(
            prepared,
            authoritative_handle,
            ("response",),
        )
    )
    settle = {
        "operation": "observe",
        "state": started_state,
        "observation": response,
    }
    settled_result = _reference_step(spec, settle, "Terminal")
    settled_state = settled_result["state"]
    stages.append(("stateful-delivery:first", settle))
    stages.extend(
        (
            (
                "stateful-delivery:exact-duplicate",
                {
                    "operation": "observe",
                    "state": settled_state,
                    "observation": response,
                },
            ),
            (
                "stateful-delivery:conflict",
                {
                    "operation": "observe",
                    "state": settled_state,
                    "observation": conflicting_delivery(response),
                },
            ),
        )
    )

    allowed_request = retry_request(prepared, allowed=True)
    allowed_retry = {
        "operation": "retry",
        "state": settled_state,
        "request": allowed_request,
    }
    retry_result = _reference_step(spec, allowed_retry, "Prepared")
    stages.extend(
        (
            ("stateful-retry:allowed", allowed_retry),
            (
                "stateful-retry:denied",
                {
                    "operation": "retry",
                    "state": settled_state,
                    "request": retry_request(prepared, allowed=False),
                },
            ),
            (
                "stateful-retry:authorization-reuse",
                {
                    "operation": "retry",
                    "state": retry_result["state"],
                    "request": allowed_request,
                },
            ),
        )
    )

    attempt = prepared["input"]["attempt"]
    no_effect = {
        "operation": "annotateEffect",
        "state": settled_state,
        "effect": effect_observation(attempt, "NoEffect"),
    }
    no_effect_result = _reference_step(spec, no_effect, "Applied")
    stages.extend(
        (
            ("stateful-effect:no-effect", no_effect),
            (
                "stateful-effect:occurred",
                {
                    "operation": "annotateEffect",
                    "state": settled_state,
                    "effect": effect_observation(attempt, "EffectOccurred"),
                },
            ),
            (
                "stateful-effect:conflict",
                {
                    "operation": "annotateEffect",
                    "state": no_effect_result["state"],
                    "effect": effect_observation(attempt, "EffectOccurred"),
                },
            ),
        )
    )
    return stages


def run_differential(*, full: bool = False, limit: int | None = None, include_mock: bool = False) -> dict[str, Any]:
    specs = runner_specs()
    unavailable_results: dict[str, RunnerObservation] = {}
    prepared_specs: list[RunnerSpec] = [specs[0]]
    for spec in specs[1:]:
        try:
            resolved, prepared = prepare_runner(spec)
        except subprocess.TimeoutExpired as exc:
            resolved, prepared = spec, _unavailable(spec, type(exc).__name__, str(exc))
        except OSError as exc:
            resolved, prepared = spec, _unavailable(spec, type(exc).__name__, str(exc))
        prepared_specs.append(resolved)
        if prepared is not None:
            unavailable_results[spec.name] = prepared
    runner_list = tuple(prepared_specs)
    invocations: list[tuple[str, dict[str, Any], tuple[str, ...]]] = []
    if full:
        for coverage, invocation in generate_model_cases(limit):
            invocations.append(("pairwise-model", invocation, coverage))
    else:
        for invocation in generate_invocations(full=False, limit=limit):
            invocations.append(
                (
                    f"pure:{invocation.get('operation', 'unknown')}",
                    invocation,
                    ("canonical",),
                )
            )
    if full:
        for malformed in generate_malformed_invocations():
            invocations.append(
                ("malformed-invocation", malformed, ("malformed-invocation",))
            )
        for observation in generate_observation_invocations():
            invocations.append(
                ("observation-domain", observation, ("observation-domain",))
            )
        for coverage, response in generate_response_cases():
            invocations.append(("response-pairwise", response, coverage))
        for clock_invocation in generate_clock_invocations():
            invocations.append(
                ("clock-basis-limit", clock_invocation, ("clock-basis-limit",))
            )
        for domain, invocation in _stateful_invocations(runner_list[0]):
            coverage = ["stateful"]
            if "reverse-order" in domain:
                coverage.append("source-delivery:reverse-order")
            elif "same-order" in domain:
                coverage.append("source-delivery:same-order")
            if domain.startswith("relation-mutation:observe:"):
                coverage.append(
                    "observation-mutation:"
                    + domain.removeprefix("relation-mutation:observe:")
                )
            if domain.startswith("timeout:"):
                coverage.append("timeout")
            if domain.startswith("stateful-retry:"):
                coverage.append("retry")
            if domain.startswith("stateful-effect:"):
                coverage.append("effect")
            invocations.append((domain, invocation, tuple(coverage)))
    observations: list[dict[str, Any]] = []
    domain_counts: dict[str, int] = {}
    coverage_domain_counts: dict[str, int] = {}
    mismatch_count = 0
    unavailable: set[str] = set()
    first_mismatch: dict[str, dict[str, Any]] = {}
    result_distributions: dict[str, dict[str, int]] = {}
    mismatch_domains: dict[str, dict[str, int]] = {}
    mismatch_examples: dict[str, list[dict[str, Any]]] = {}
    failure_distributions: dict[str, dict[str, int]] = {}
    comparison_counts = {
        spec.name: {"matched": 0, "mismatched": 0, "unavailable": 0}
        for spec in runner_list[1:]
    }

    for domain, invocation, coverage_domains in invocations:
        domain_counts[domain] = domain_counts.get(domain, 0) + 1
        for coverage_domain in coverage_domains:
            coverage_domain_counts[coverage_domain] = (
                coverage_domain_counts.get(coverage_domain, 0) + 1
            )
        reference = invoke(runner_list[0], invocation)
        result_tag = str(reference.observation.get("result"))
        distribution = result_distributions.setdefault(domain, {})
        distribution[result_tag] = distribution.get(result_tag, 0) + 1
        if result_tag == "Rejected":
            failure_tag = str(reference.observation.get("failure", {}).get("tag"))
            failures = failure_distributions.setdefault(domain, {})
            failures[failure_tag] = failures.get(failure_tag, 0) + 1
        lanes: list[dict[str, Any]] = []
        for spec in runner_list[1:]:
            result = unavailable_results.get(spec.name)
            if result is None:
                result = invoke(spec, invocation)
                if not result.available:
                    unavailable_results[spec.name] = result
            if not result.available:
                unavailable.add(result.lane)
                comparison_counts[spec.name]["unavailable"] += 1
            matches = comparable(result.observation) == comparable(reference.observation) if result.available and reference.available else None
            if matches is True:
                comparison_counts[spec.name]["matched"] += 1
            if matches is False:
                comparison_counts[spec.name]["mismatched"] += 1
                mismatch_count += 1
                first_mismatch.setdefault(spec.name, {"domain": domain, "invocation": invocation, "reference": reference.observation, "lane": result.observation})
                by_domain = mismatch_domains.setdefault(spec.name, {})
                by_domain[domain] = by_domain.get(domain, 0) + 1
                examples = mismatch_examples.setdefault(spec.name, [])
                if len(examples) < 3:
                    examples.append({"domain": domain, "invocation": invocation, "reference": reference.observation, "lane": result.observation})
            lanes.append({"lane": result.lane, "available": result.available, "matchesReference": matches, "observation": result.observation})
        observations.append({"domain": domain, "coverageDomains": list(coverage_domains), "invocation": invocation, "reference": reference.observation, "referenceAvailable": reference.available, "lanes": lanes})
    model_pairwise = pairwise_coverage()
    response_pairwise = response_pairwise_coverage()
    report: dict[str, Any] = {
        "result": "Differential",
        "invocationCount": len(invocations),
        "domainCounts": domain_counts,
        "coverageDomainCounts": coverage_domain_counts,
        "finiteDomains": {name: len(values) for name, values in finite_domains().items()},
        "pairwiseCoverage": {
            "model": model_pairwise,
            "response": response_pairwise,
            "allCovered": all(
                item["covered"] == item["required"]
                for item in (*model_pairwise.values(), *response_pairwise.values())
            ),
        },
        "resultDistributions": result_distributions,
        "leanResultDistributions": result_distributions,
        "leanFailureDistributions": failure_distributions,
        "observations": observations,
        "availableLanes": [row["lane"] for row in observations[0]["lanes"] if row["available"]] if observations else [],
        "unavailableLanes": sorted(unavailable),
        "mismatchCount": mismatch_count,
        "comparisonCountsByLane": comparison_counts,
        "mismatchCountByLane": {
            lane: counts["mismatched"]
            for lane, counts in comparison_counts.items()
        },
        "firstMismatchByLane": first_mismatch,
        "mismatchDomainsByLane": mismatch_domains,
        "firstThreeMismatchesByLane": mismatch_examples,
    }
    if include_mock:
        race_cases = tuple(generate_race_cases())
        report["mockRaces"] = [
            run_race(case["order"], case["sourceSequences"])
            for case in race_cases
        ]
        report["domainCounts"]["mock-races"] = len(race_cases)
        report["coverageDomainCounts"]["mock-source-delivery:reverse-order"] = sum(
            case["relation"] == "reverse-order" for case in race_cases
        )
        report["coverageDomainCounts"]["mock-source-delivery:same-order"] = sum(
            case["relation"] == "same-order" for case in race_cases
        )
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--mock", action="store_true")
    parser.add_argument("--races", action="store_true")
    parser.add_argument("--late", action="store_true")
    parser.add_argument("--duplicates", action="store_true")
    parser.add_argument("--effects", action="store_true")
    parser.add_argument("--retry", action="store_true")
    args = parser.parse_args()
    if not (args.all or any((args.mock, args.races, args.late, args.duplicates, args.effects, args.retry))):
        parser.error("choose --all or a Differential mode")
    report = run_differential(full=args.all, include_mock=any((args.mock, args.races, args.late, args.duplicates, args.effects, args.retry)))
    print(json.dumps(report, sort_keys=True))
    return 1 if report["unavailableLanes"] else 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = ["normalize", "run_differential", "runner_specs"]
