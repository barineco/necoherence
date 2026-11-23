#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import atexit
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

NECO_QUOTIENT_JAVA = os.environ.get("NCOH_NECO_QUOTIENT_JAVA", "")
NECO_QUOTIENT_APPLICATION_JAVA = os.environ.get("NCOH_NECO_QUOTIENT_APPLICATION_JAVA", "")
NECO_QUOTIENT_RETENTION_JAVA = os.environ.get("NCOH_NECO_QUOTIENT_RETENTION_JAVA", "")
NECO_QUOTIENT_ENCODING_JAVA = os.environ.get("NCOH_NECO_QUOTIENT_ENCODING_JAVA", "")


def java_sourcepath() -> list[str]:
    if not NECO_QUOTIENT_JAVA:
        raise SystemExit("NCOH_NECO_QUOTIENT_JAVA must name neco-quotient's java/src/main/java")
    if not NECO_QUOTIENT_APPLICATION_JAVA:
        raise SystemExit("NCOH_NECO_QUOTIENT_APPLICATION_JAVA must name neco-quotient's application/java/src/main/java")
    if not NECO_QUOTIENT_RETENTION_JAVA:
        raise SystemExit("NCOH_NECO_QUOTIENT_RETENTION_JAVA must name neco-quotient's retention/java/src/main/java")
    if not NECO_QUOTIENT_ENCODING_JAVA:
        raise SystemExit("NCOH_NECO_QUOTIENT_ENCODING_JAVA must name neco-quotient's encoding/java/src/main/java")
    return ["-sourcepath", os.pathsep.join((NECO_QUOTIENT_JAVA, NECO_QUOTIENT_APPLICATION_JAVA, NECO_QUOTIENT_RETENTION_JAVA, NECO_QUOTIENT_ENCODING_JAVA))]

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
# The build guard accepts cargo and gleam packages only under the workspace root and keeps one build lane per
# package root, so the generated packages are built in a fixed directory of this worktree that is removed at exit.
PACKAGES = HERE / "generated-packages"
RUST_SCRATCH = PACKAGES / "generated-rust"
GLEAM_SCRATCH = PACKAGES / "generated-gleam"

spec = importlib.util.spec_from_file_location("composition_check", ROOT / "solver/composition/verification/check.py")
if spec is None or spec.loader is None:
    raise RuntimeError("composition comparison helpers unavailable")
composition_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(composition_check)
command = composition_check.command
cargo = composition_check.cargo
canonical = composition_check.canonical
exhaustive_spec = importlib.util.spec_from_file_location(
    "signature_admission_exhaustive", ROOT / "verification/declaration/signature_admission_exhaustive.py")
if exhaustive_spec is None or exhaustive_spec.loader is None:
    raise RuntimeError("goal observation helpers unavailable")
exhaustive = importlib.util.module_from_spec(exhaustive_spec)
sys.modules["signature_admission_exhaustive"] = exhaustive
exhaustive_spec.loader.exec_module(exhaustive)

FAILURE_NAME_MAP = {
    "lean": {name: name for name in ("value", "missingArgument", "argumentCoverage", "missingValue", "missingProvider", "providerCoverage", "providerEffect", "provider", "invalidOutcome", "resource", "invalidPlan", "network", "networkTerminal")},
    "rust": {name[0].upper() + name[1:]: name for name in ("value", "missingArgument", "argumentCoverage", "missingValue", "missingProvider", "providerCoverage", "providerEffect", "provider", "invalidOutcome", "resource", "invalidPlan", "network", "networkTerminal")},
    "python": {**{name[0].upper() + name[1:]: name for name in ("missingArgument", "argumentCoverage", "missingValue", "missingProvider", "providerCoverage", "providerEffect", "invalidOutcome", "invalidPlan")}, "ValueFailure": "value", "ResourceFailure": "resource", "ProviderFailure": "provider", "NetworkFailure": "network", "NetworkTerminalFailure": "networkTerminal"},
    "typescript": {name[0].upper() + name[1:]: name for name in ("value", "missingArgument", "argumentCoverage", "missingValue", "missingProvider", "providerCoverage", "providerEffect", "provider", "invalidOutcome", "resource", "invalidPlan", "network", "networkTerminal")},
    "java": {**{name[0].upper() + name[1:]: name for name in ("value", "missingArgument", "argumentCoverage", "missingValue", "missingProvider", "providerCoverage", "providerEffect", "invalidOutcome", "resource", "invalidPlan", "network", "networkTerminal")}, "ProviderFailure": "provider"},
    "gleam": {**{name[0].upper() + name[1:]: name for name in ("value", "missingArgument", "argumentCoverage", "missingValue", "missingProvider", "providerCoverage", "providerEffect", "invalidOutcome", "resource", "invalidPlan", "network", "networkTerminal")}, "ProviderFailure": "provider"},
}


def generated_exchanges() -> dict[str, str]:
    manifest = HERE / "rust_driver/Cargo.toml"
    output = command(
        [cargo(), "run", "--locked", "--quiet", "--manifest-path", str(manifest), "--bin", "generate"],
        input_text=canonical({"scenarios": ["pure", "http", "presence", "validate", "variant", "variant_projection", "flow", "field", "index", "sequence"]}),
    )
    return json.loads(output)


def request(ordinal: int = 0, provenance: str = "comparison") -> dict:
    return {"method": "GET", "target": "http://127.0.0.1/execution", "headers": [], "body": [], "ordinal": ordinal, "provenance": provenance}


def provider(effect: str, outcome: str, outputs: list[dict[str, object]], *, decode_failure: bool = False, signature: int = 0) -> dict:
    value = {"reference": "declared", "effect": effect}
    value["signature"] = signature
    if effect == "pure":
        return {**value, "outcome": outcome, "outputs": outputs}
    decoded = {"failure": {"tag": "provider", "message": "decode"}} if decode_failure else {"outcome": outcome, "outputs": outputs}
    prepared = request()
    return {**value, "request": prepared, "prepare": [{"tag": "ready", "request": prepared}], "decode": [{"status": 200, **decoded}]}


def cases() -> dict:
    exchanges = generated_exchanges()
    argument = [{"id": "argument", "value": {"tag": "present", "value": True}}]
    success = [{"id": "output", "value": {"tag": "present", "value": True}}]
    refused = [{"id": "reason", "value": {"tag": "present", "value": None}}]
    started = {"tag": "start", "kind": "started", "handle": "handle"}
    response = {"tag": "host", "status": 200, "headers": [], "body": []}
    known = {"tag": "present", "value": {"kind": "known", "value": "matched"}}
    otherwise = {"tag": "present", "value": {"kind": "other", "value": "fallback"}}
    completed_refusal = provider("http", "refused", refused)
    completed_refusal["prepare"] = [{"tag": "completed", "outcome": "refused", "outputs": refused}]
    completed_unknown = provider("http", "undeclared", [])
    completed_unknown["prepare"] = [{"tag": "completed", "outcome": "undeclared", "outputs": []}]
    completed_unknown["decode"] = [{"status": 200, "outcome": "success", "outputs": success}]
    sequence_first = provider("http", "success", success, signature=0)
    sequence_first["prepare"] = [{"tag": "ready", "request": request(0)}]
    sequence_second = provider("http", "success", success, signature=1)
    sequence_second["prepare"] = [{"tag": "ready", "request": request(0, "comparison-second")}]
    sequence_second["decode"] = [
        {"status": 200, "outcome": "success", "outputs": success},
        {"status": 201, "outcome": "success", "outputs": [{"id": "output", "value": {"tag": "present", "value": False}}]},
    ]
    sequence_providers = [sequence_first, sequence_second]
    first_started = {"tag": "start", "kind": "started", "handle": "first", "request": 0}
    first_response = {"tag": "host", "status": 200, "headers": [], "body": [], "handle": "first", "request": 0, "delivery": 0}
    second_started = {"tag": "start", "kind": "started", "handle": "second", "request": 1}
    rows = [
        {"case": "pure/success", "exchange": exchanges["pure"], "arguments": argument, "providers": [provider("pure", "success", success)], "observations": []},
        {"case": "arguments/value-failure", "exchange": exchanges["pure"], "arguments": [{"id": "argument", "value": {"tag": "absent"}}], "providers": [provider("pure", "success", success)], "observations": []},
        {"case": "arguments/value-failure-observed", "exchange": exchanges["pure"], "arguments": [{"id": "argument", "value": {"tag": "present", "value": "not-boolean"}}], "providers": [provider("pure", "success", success)], "observations": []},
        {"case": "pure/declared-failure", "exchange": exchanges["pure"], "arguments": argument, "providers": [provider("pure", "refused", refused)], "observations": []},
        {"case": "pure/invalid-outcome", "exchange": exchanges["pure"], "arguments": argument, "providers": [provider("pure", "undeclared", [])], "observations": []},
        {"case": "providers/missing", "exchange": exchanges["pure"], "arguments": argument, "providers": [{**provider("pure", "success", success), "reference": "other"}], "observations": []},
        {"case": "providers/effect", "exchange": exchanges["pure"], "arguments": argument, "providers": [provider("http", "success", success)], "observations": []},
        {"case": "providers/duplicate", "exchange": exchanges["pure"], "arguments": argument, "providers": [provider("pure", "success", success), provider("pure", "success", success)], "observations": []},
        {"case": "arguments/missing", "exchange": exchanges["pure"], "arguments": [], "providers": [provider("pure", "success", success)], "observations": []},
        {"case": "arguments/duplicate", "exchange": exchanges["pure"], "arguments": argument + argument, "providers": [provider("pure", "success", success)], "observations": []},
        {"case": "http/success", "exchange": exchanges["http"], "arguments": argument, "providers": [provider("http", "success", success)], "observations": [started, response]},
        {"case": "http/start-terminal", "exchange": exchanges["http"], "arguments": argument, "providers": [provider("http", "success", success)], "observations": [{"tag": "start", "kind": "failed"}]},
        {"case": "http/observation-kind-mismatch", "exchange": exchanges["http"], "arguments": argument, "providers": [provider("http", "success", success)], "observations": [response]},
        {"case": "http/observation-handle-mismatch", "exchange": exchanges["http"], "arguments": argument, "providers": [provider("http", "success", success)], "observations": [started, {**response, "handle": "other"}]},
        {"case": "http/decode-failure", "exchange": exchanges["http"], "arguments": argument, "providers": [provider("http", "success", success, decode_failure=True)], "observations": [started, response]},
        {"case": "http/precompleted-declared-external", "exchange": exchanges["http"], "arguments": argument, "providers": [completed_refusal], "observations": []},
        {"case": "http/precompleted-undeclared", "exchange": exchanges["http"], "arguments": argument, "providers": [completed_unknown], "observations": []},
        {"case": "guard/presence-present", "exchange": exchanges["presence"], "arguments": [{"id": "argument", "value": {"tag": "present", "value": "present-value"}}], "providers": [], "observations": []},
        {"case": "guard/presence-absent", "exchange": exchanges["presence"], "arguments": [{"id": "argument", "value": {"tag": "absent"}}], "providers": [], "observations": []},
        {"case": "guard/presence-null", "exchange": exchanges["presence"], "arguments": [{"id": "argument", "value": {"tag": "null"}}], "providers": [], "observations": []},
        {"case": "guard/validate-accepted", "exchange": exchanges["validate"], "arguments": [{"id": "argument", "value": {"tag": "present", "value": "validated-value"}}], "providers": [], "observations": []},
        {"case": "guard/validate-rejected", "exchange": exchanges["validate"], "arguments": [{"id": "argument", "value": {"tag": "absent"}}], "providers": [], "observations": []},
        {"case": "guard/variant-known", "exchange": exchanges["variant"], "arguments": [{"id": "argument", "value": known}], "providers": [], "observations": []},
        {"case": "guard/variant-otherwise", "exchange": exchanges["variant"], "arguments": [{"id": "argument", "value": otherwise}], "providers": [], "observations": []},
        {"case": "guard/variant-absent", "exchange": exchanges["variant"], "arguments": [{"id": "argument", "value": {"tag": "absent"}}], "providers": [], "observations": []},
        {"case": "guard/variant-null", "exchange": exchanges["variant"], "arguments": [{"id": "argument", "value": {"tag": "null"}}], "providers": [], "observations": []},
        {"case": "binding/product-and-resource-lot-consumption", "exchange": exchanges["flow"], "arguments": [
            {"id": "left", "value": {"tag": "present", "value": True}},
            {"id": "right", "value": {"tag": "present", "value": False}},
        ], "providers": [{"reference": "declared", "effect": "pure", "outcome": "success", "outputs": [
            {"id": "pair", "value": {"tag": "present", "value": {"left": True, "right": False}}},
        ]}], "observations": []},
        {"case": "projection/field", "exchange": exchanges["field"], "arguments": [{"id": "argument", "value": {"tag": "present", "value": {"left": False, "right": True}}}], "providers": [], "observations": []},
        {"case": "projection/index", "exchange": exchanges["index"], "arguments": [{"id": "argument", "value": {"tag": "present", "value": [False, True]}}], "providers": [], "observations": []},
        {"case": "projection/variant", "exchange": exchanges["variant_projection"], "arguments": [{"id": "argument", "value": known}], "providers": [], "observations": []},
        {"case": "resume/duplicate-observation", "exchange": exchanges["sequence"], "arguments": [], "providers": sequence_providers, "observations": [
            first_started, first_response, second_started,
            first_response,
            {"tag": "host", "status": 200, "headers": [], "body": [], "handle": "second", "request": 1, "delivery": 0},
        ]},
        {"case": "resume/late-observation", "exchange": exchanges["sequence"], "arguments": [], "providers": sequence_providers, "observations": [
            first_started, first_response, second_started,
            {**first_response, "delivery": 1},
            {"tag": "host", "status": 201, "headers": [], "body": [], "handle": "second", "request": 1, "delivery": 0},
        ]},
    ]
    unique = composition_check.generated_unique(canonical(composition_check.generator("composition")))
    _, forged_plan = composition_check.changed_exchange(
        unique, lambda derivation: derivation["selection"]["fields"].__setitem__("canonical_plan", "forged"))
    rows.append({"case": "unique/wire-canonical-plan-forged", "exchange": forged_plan, "arguments": [], "providers": [
        provider("http", "success", success, signature=0),
        provider("pure", "handled", success, signature=1),
    ], "observations": [started, response]})
    for row in rows:
        exchange = json.loads(row["exchange"])
        row["expected"] = canonical(exhaustive.expected_document(exchange["basis"], exchange["composition"]))
    return {"schema": "ncoh-execution-comparison@1", "cases": rows}


def runners(input_path: Path, java_build: Path) -> dict[str, tuple[list[str], Path]]:
    java_library = os.environ.get(
        "NCOH_JAVA_EXECUTION_CLASSPATH",
        str(ROOT / "packages/java/adapter/build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar"),
    )
    return {
        "lean": (["lake", "env", "lean", "--run", "../../verification/execution/lean_runner.lean", str(input_path)], ROOT / "generator/lean"),
        "rust": ([cargo(), "run", "--locked", "--quiet", "--manifest-path", str(HERE / "rust_driver/Cargo.toml"), "--bin", "execution_comparison_driver", "--", str(input_path)], ROOT),
        "python": ([sys.executable, str(HERE / "python_driver.py"), str(input_path)], ROOT),
        "typescript": (["node", "--import", "tsx", "../../../verification/execution/ts_driver.ts", str(input_path)], ROOT / "packages/typescript/adapter"),
        "java": (["java", "--class-path", str(java_build) + os.pathsep + java_library, "necoherence.comparison.ExecutionCheck", str(input_path)], ROOT),
        "gleam": (["gleam", "run", "-m", "execution_check", "--", str(input_path)], Path(os.environ.get("NCOH_GLEAM_EXECUTION_DIR", HERE / "gleam_driver"))),
    }


def generated_document(document: dict) -> dict:
    kernel_only = {"pure/invalid-outcome", "providers/missing", "providers/effect", "providers/duplicate", "arguments/missing", "arguments/duplicate", "arguments/value-failure", "arguments/value-failure-observed", "http/observation-kind-mismatch", "http/observation-handle-mismatch"}
    return {**document, "cases": [row for row in document["cases"] if row["case"] not in kernel_only]}


def generated_runners(input_path: Path, scratch: Path) -> dict[str, tuple[list[str], Path]]:
    return {
        "lean": ([sys.executable, str(HERE / "generated_lean_driver.py"), str(input_path), str(scratch / "lean")], ROOT),
        "rust": ([sys.executable, str(HERE / "generated_rust_driver.py"), str(input_path), str(RUST_SCRATCH)], ROOT),
        "python": ([sys.executable, str(HERE / "generated_python_driver.py"), str(input_path)], ROOT),
        "typescript": (["node", "--import", "tsx", "../../../verification/execution/generated_ts_driver.ts", str(input_path), str(scratch / "typescript")], ROOT / "packages/typescript/adapter"),
        "java": ([sys.executable, str(HERE / "generated_java_driver.py"), str(input_path), str(scratch / "java")], ROOT),
        "gleam": ([sys.executable, str(HERE / "generated_gleam_driver.py"), str(input_path), str(GLEAM_SCRATCH)], ROOT),
    }


def normalized(language: str, row: dict) -> dict:
    value = dict(row)
    if "failure" in value:
        failure = value["failure"]
        name = failure["tag"] if isinstance(failure, dict) else failure
        mapped = FAILURE_NAME_MAP[language].get(name)
        if mapped is None:
            raise RuntimeError(f"{language} returned an unmapped failure name: {name}")
        if isinstance(failure, dict):
            value["failure"] = {**failure, "tag": mapped}
        else:
            value["failure"] = {"tag": mapped}
    return value


def main() -> int:
    atexit.register(shutil.rmtree, PACKAGES, ignore_errors=True)
    selected = set(sys.argv[1:])
    with tempfile.TemporaryDirectory(prefix="ncoh-execution-") as directory:
        path = Path(directory) / "cases.json"
        document = cases()
        path.write_text(canonical(document), encoding="utf-8")
        java_build = Path(directory) / "java"
        java_build.mkdir()
        if not selected or "java" in selected:
            java_library = os.environ.get(
                "NCOH_JAVA_EXECUTION_CLASSPATH",
                str(ROOT / "packages/java/adapter/build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar"),
            )
            quotient_sources = sorted(str(source) for root in (NECO_QUOTIENT_JAVA, NECO_QUOTIENT_APPLICATION_JAVA, NECO_QUOTIENT_RETENTION_JAVA, NECO_QUOTIENT_ENCODING_JAVA) for source in Path(root).rglob("*.java"))
            command(["javac", "--release", "21", "-cp", java_library, *java_sourcepath(), "-d", str(java_build),
                     str(HERE / "java_driver/NetworkFailureJson.java"), str(HERE / "java_driver/ValueFailureJson.java"),
                     str(HERE / "java_driver/ExecutionCheck.java"), *quotient_sources])
        specs = runners(path, java_build)
        if selected:
            specs = {language: spec for language, spec in specs.items() if language in selected}
        outputs = {language: {row["case"]: row for row in json.loads(command(argv, cwd=cwd))} for language, (argv, cwd) in specs.items()}
        if "lean" not in outputs:
            failed = False
            for identity in next(iter(outputs.values())):
                rows = {language: table[identity] for language, table in outputs.items()}
                print(canonical({"case": identity, "results": rows}))
                baseline_language = next(iter(outputs))
                baseline = normalized(baseline_language, outputs[baseline_language][identity])
                if any(normalized(language, table[identity]) != baseline for language, table in outputs.items()):
                    failed = True
                    print(f"{identity}: languages differ; Lean result unavailable", file=sys.stderr)
            core_failed = failed
        else:
            core_failed = False
            for identity in outputs["lean"]:
                print(canonical({"phase": "kernel", "case": identity, "results": {language: table[identity] for language, table in outputs.items()}}))
                expected = normalized("lean", outputs["lean"][identity])
                for language, table in outputs.items():
                    if normalized(language, table[identity]) != expected:
                        core_failed = True
                        print(f"kernel {identity}: {language} differs from Lean", file=sys.stderr)

        generated_path = Path(directory) / "generated-cases.json"
        generated_path.write_text(canonical(generated_document(document)), encoding="utf-8")
        generated_specs = generated_runners(generated_path, Path(directory) / "generated")
        if selected:
            generated_specs = {language: spec for language, spec in generated_specs.items() if language in selected}
        if not generated_specs:
            return int(core_failed)
        generated_outputs = {language: {row["case"]: row for row in json.loads(command(argv, cwd=cwd))} for language, (argv, cwd) in generated_specs.items()}
        generated_failed = False
        baseline_language = "lean" if "lean" in generated_outputs else next(iter(generated_outputs))
        for identity in generated_outputs[baseline_language]:
            rows = {language: table[identity] for language, table in generated_outputs.items()}
            print(canonical({"phase": "generated", "case": identity, "results": rows}))
            baseline = rows[baseline_language]
            for language, row in rows.items():
                if row != baseline:
                    generated_failed = True
                    suffix = "" if baseline_language == "lean" else "; Lean result unavailable"
                    print(f"generated {identity}: {language} differs from {baseline_language}{suffix}", file=sys.stderr)
        return int(core_failed or generated_failed)


if __name__ == "__main__":
    raise SystemExit(main())

