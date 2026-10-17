# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from semantic_invariant_inputs import generate, wire_cases
from preset_representative_inputs import generate_preset_cases, rename_decision, sigma_case

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ("python", "typescript", "rust", "java", "gleam")
SUPPORTED_OPERATIONS = {
    "python": {"profile", "library", "value", "inclusion", "samples"},
    "typescript": {"profile", "library", "value", "inclusion", "samples"},
    "java": {"profile", "library", "value", "inclusion", "samples"},
    "rust": {"profile", "library", "value", "inclusion", "samples"},
    "gleam": {"profile", "library", "value", "inclusion", "samples"},
}


def execute(command, *, cwd=ROOT, input_text=None, env=None, timeout=1200):
    result = subprocess.run([str(item) for item in command], cwd=cwd, text=True,
                            input=input_text, capture_output=True, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError(json.dumps({"command": [str(item) for item in command],
                                       "stdout": result.stdout, "stderr": result.stderr}, ensure_ascii=False))
    return result.stdout


def batch(command, cases, *, cwd=ROOT, env=None):
    if not cases:
        return []
    text = "".join(json.dumps(case, ensure_ascii=False, separators=(",", ":")) + "\n" for case in cases)
    output = execute(command, cwd=cwd, input_text=text, env=env)
    rows = [json.loads(line) for line in output.splitlines() if line.strip()]
    if len(rows) != len(cases):
        raise RuntimeError(json.dumps({"kind": "AdapterRowCount", "expected": len(cases),
                                       "actual": len(rows), "output": output}, ensure_ascii=False))
    return rows


def exact_json(value):
    if value is None:
        return {"tag": "Null"}
    if type(value) is bool:
        return {"tag": "Bool", "value": value}
    if type(value) is int:
        return {"tag": "Integer", "value": str(value)}
    if type(value) is float:
        return {"tag": "Decimal", "text": str(value)}
    if type(value) is str:
        return {"tag": "String", "value": value}
    if type(value) is list:
        return {"tag": "Array", "items": [exact_json(item) for item in value]}
    if type(value) is dict:
        return {"tag": "Object", "members": [{"key": key, "value": exact_json(item)} for key, item in value.items()]}
    raise TypeError(f"unsupported representative JSON value: {value!r}")


def adapter_input(language, case):
    operation = case["operation"]
    common = copy.deepcopy({key: value for key, value in case.items() if key != "rule"})
    if language == "lean":
        common["kind"] = "inclusion_by_id" if operation == "inclusion" else operation
        common.pop("operation", None)
        return common
    if language == "rust":
        from necoherence.type_signatures import signature_basis
        library = common["library"]
        exchange_library = copy.deepcopy(library)
        for wrapper in exchange_library["profile"]["wrappers"]:
            payload = wrapper["payload"]
            if payload["tag"] == "Text":
                payload["fields"] = {"format": payload.pop("value")}
        for node in exchange_library["nodes"]:
            shape = node["shape"]
            if shape.get("tag") != "TaggedUnion":
                continue
            for branch in shape["value"]["branches"]:
                selector = branch["selector"]
                if selector.get("tag") == "MemberShape":
                    selector["value"] = [[test["key"], test["test"]] for test in selector["value"]]
        entrypoints = [{"identity": row["wire_identity"], "definition": row["id"]}
                       for row in library["definitions"]]
        common["exchange"] = {
            "schema": "ncoh-checked-generation@4",
            "basis": signature_basis(library, entrypoints),
            "signatures": exchange_library,
            "composition": None,
            "entrypoints": entrypoints,
        }
        common["kind"] = "admit" if operation in ("profile", "library") else operation
        if operation == "value":
            common["value"] = exact_json(common["value"])
        common.pop("operation", None)
        return common
    if language == "typescript":
        for node in common.get("library", {}).get("nodes", []):
            shape = node.get("shape", {})
            if shape.get("tag") != "TaggedUnion":
                continue
            for branch in shape["value"]["branches"]:
                selector = branch["selector"]
                if selector.get("tag") == "MemberShape":
                    selector["value"] = [[test["key"], test["test"]] for test in selector["value"]]
        if operation == "value":
            common["value"] = exact_json(common["value"])
        return common
    if language == "python":
        common["kind"] = operation
        common.pop("operation", None)
        if operation == "profile":
            common["profile"] = common["library"]["profile"]
        if operation == "inclusion":
            common["source"] = {"type_id": common.pop("type_id")}
            common["destination"] = {"type_id": common.pop("destination_type_id")}
        return common
    if language in ("java", "gleam"):
        common["kind"] = operation
        common.pop("operation", None)
        if language == "java" and operation in ("profile", "library"):
            common["kind"] = "profile_admission"
        if operation == "inclusion":
            common["source"] = {"type_id": common.pop("type_id"), "required": True, "nullable": False}
            common["destination"] = {"type_id": common.pop("destination_type_id"), "required": True, "nullable": False}
            common["candidates"] = []
        return common
    raise ValueError(language)


def normalized(operation, row):
    failure = row.get("failure", {})
    status = row.get("status") or row.get("classification")
    condition = row.get("condition", failure.get("condition"))
    if isinstance(condition, str):
        match = re.fullmatch(r'(\w+)\("([^"]*)"\)', condition)
        if match:
            condition = f"{match.group(1)}:{match.group(2)}"
    if isinstance(status, str):
        status = status[:1].upper() + status[1:].lower()
    if operation in ("profile", "library"):
        predicate = row.get("predicate", failure.get("predicate"))
        path = row.get("path", failure.get("location", []))
        message = row.get("message", "")
        rust_failure = re.search(r"predicate: (Pr|Lb)(\d+), location: \[\"([^\"]+)\"\]", message)
        if status == "Error" and rust_failure:
            status = "Rejected"
            predicate = (rust_failure.group(1) + rust_failure.group(2)).upper()
            path = [rust_failure.group(3)]
        return {"status": status, "predicate": predicate, "path": path}
    if operation == "value":
        return {"status": status, "type_ref": row.get("type_ref", failure.get("type_ref")),
                "condition": condition, "path": row.get("path", failure.get("path", [])),
                "trace": row.get("trace", failure.get("trace", []))}
    if operation == "inclusion":
        return {"status": status}
    if operation == "samples":
        if "sample_count" in row:
            possible = int(row["sample_count"]) > 0
        else:
            possible = row.get("possible", bool(row.get("values", [])))
        if status == "Samples":
            status = "Accepted"
        obligations = str(row.get("obligations", ""))
        return {"status": status or "Accepted",
                "sample_bound": row.get("sample_bound", row.get("sampleBound", "SampleBound" in obligations)),
                "possible": possible}
    if operation == "wire":
        return {"status": status, "classification": row.get("classification", failure.get("classification")),
                "path": row.get("path", failure.get("path")), "encoded": row.get("encoded")}
    raise ValueError(operation)

def mismatch_classification(case):
    return {"classification": "language-side"}


def build_commands(languages, directory):
    lean_dir = ROOT / "tools/lean"
    execute(["lake", "build", "semantic_invariant"], cwd=lean_dir)
    lean_launcher = directory / "lean_runner"
    lean_launcher.write_text("#!/bin/sh\ncd " + shlex.quote(str(lean_dir)) + " || exit\nexec lake exe semantic_invariant \"$@\"\n", encoding="utf-8")
    lean_launcher.chmod(0o700)
    commands = {"lean": [lean_launcher],
                "python": [sys.executable, ROOT / "tools/python/semantic_invariant_adapter.py"]}
    if "typescript" in languages:
        for package in (ROOT / "typescript", ROOT / "tools/typescript"):
            if not (package / "node_modules").exists():
                execute(["npm", "ci"], cwd=package)
            execute(["npm", "run", "build"], cwd=package)
        commands["typescript"] = ["node", ROOT / "tools/typescript/tests/semantic-invariants.mjs"]
    if "rust" in languages:
        envelope_output = execute([
            "cargo", "build", "--manifest-path",
            ROOT / "comparison/declaration/signature_generator/Cargo.toml",
            "--bin", "rust_generation_envelope", "--message-format=json",
        ], env={**os.environ, "CARGO_TARGET_DIR": str(directory / "cargo")})
        commands["rust_envelope"] = [next(
            json.loads(line)["executable"] for line in envelope_output.splitlines()
            if json.loads(line).get("target", {}).get("name") == "rust_generation_envelope"
            and json.loads(line).get("executable")
        )]
        output = execute(["cargo", "build", "--manifest-path", ROOT / "tools/rust/Cargo.toml",
                          "--example", "semantic_invariant_adapter", "--message-format=json"],
                         env={**os.environ, "CARGO_TARGET_DIR": str(directory / "cargo")})
        commands["rust"] = [next(json.loads(line)["executable"] for line in output.splitlines()
                                 if json.loads(line).get("executable"))]
    if "java" in languages:
        classes = directory / "java"
        classes.mkdir()
        sources = sorted((ROOT / "java/src/main/java").rglob("*.java"))
        sources += sorted((ROOT / "tools/java/src/main/java").rglob("*.java"))
        sources += [ROOT / "tools/java/src/test/java/necoherence/tools/renderer/SemanticInvariantAdapter.java"]
        execute(["javac", "-d", classes, *sources])
        commands["java"] = ["java", "-cp", classes, "necoherence.tools.renderer.SemanticInvariantAdapter"]
    if "gleam" in languages:
        commands["gleam"] = ["gleam", "run", "--no-print-progress", "-m", "necoherence_tools/semantic_invariant_runner"]
    return commands


def run_declaration_representatives(languages):
    started = time.monotonic()
    cases = generate()
    with tempfile.TemporaryDirectory(prefix="ncoh-declarations-") as name:
        directory = Path(name)
        commands = build_commands(languages, directory)
        lean_inputs = [adapter_input("lean", case) for case in cases]
        lean_rows = batch(commands["lean"], lean_inputs)
        expected = {case["id"]: normalized(case["operation"], row) for case, row in zip(cases, lean_rows)}
        mismatches = []
        counts = {}
        for language in languages:
            selected = [case for case in cases if case["operation"] in SUPPORTED_OPERATIONS[language]]
            inputs = [adapter_input(language, case) for case in selected]
            if language == "rust":
                envelope_rows = batch(commands["rust_envelope"], [
                    {
                        "library": row["exchange"]["signatures"],
                        "entrypoints": row["exchange"]["entrypoints"],
                    }
                    for row in inputs
                ])
                for row, envelope in zip(inputs, envelope_rows):
                    if "exchange" in envelope:
                        row["exchange"] = envelope["exchange"]
            cwd = ROOT / "tools/gleam" if language == "gleam" else ROOT
            try:
                rows = batch(commands[language], inputs, cwd=cwd)
            except RuntimeError as failure:
                counts[language] = 0
                mismatches.append({
                    "classification": "language-side",
                    "language": language,
                    "input": selected,
                    "lean": [expected[case["id"]] for case in selected],
                    "actual": {"execution_failure": str(failure)},
                })
                continue
            counts[language] = len(rows)
            for case, row in zip(selected, rows):
                actual = normalized(case["operation"], row)
                if actual != expected[case["id"]]:
                    mismatches.append({**mismatch_classification(case), "language": language,
                                       "input": case, "lean": expected[case["id"]], "actual": actual})
        if "python" in languages:
            from necoherence.type_signatures import signature_basis
            wires = wire_cases(signature_basis)
            lean_wire = batch(commands["lean"], [adapter_input("lean", case) for case in wires])
            python_wire = batch(commands["python"], [adapter_input("python", case) for case in wires])
            for case, lean_row, row in zip(wires, lean_wire, python_wire):
                wanted = normalized("wire", lean_row)
                actual = normalized("wire", row)
                if actual != wanted:
                    mismatches.append({**mismatch_classification(case), "language": "python",
                                       "input": case, "lean": wanted, "actual": actual})
            counts["python"] += len(wires)
        evidence = {"mode": "declaration-representatives", "input_count": len(cases),
                    "language_counts": counts,
                    "skipped_operations": {language: sorted(
                        {case["operation"] for case in cases} - SUPPORTED_OPERATIONS[language])
                        for language in languages},
                    "mismatch_count": len(mismatches),
                    "elapsed_seconds": round(time.monotonic() - started, 3)}
        print(json.dumps({"evidence": evidence, "mismatches": mismatches}, ensure_ascii=False, sort_keys=True))
        return 1 if mismatches else 0


def recorded_input(case):
    profile = case["library"]["profile"]["reference"]
    result = {
        "id": case["id"],
        "operation": case["operation"],
        "library": case["library"]["identity"],
        "profile": profile,
    }
    for key in ("type_id", "value"):
        if key in case:
            result[key] = case[key]
    return result


def generation_documents(cases):
    from necoherence.type_signatures import decode_generation, encode_generation, signature_basis

    libraries = {}
    for case in cases:
        library = case["library"]
        libraries.setdefault(library["identity"], library)
    documents = []
    for library in libraries.values():
        entrypoints = [
            {"identity": row["wire_identity"], "definition": row["id"]}
            for row in library["definitions"]
        ]
        generation = {
            "schema": "ncoh-checked-generation@4",
            "basis": signature_basis(library, entrypoints),
            "signatures": library,
            "composition": None,
            "entrypoints": entrypoints,
        }
        canonical = encode_generation(decode_generation(generation))
        documents.append({
            "id": f"{library['profile']['reference']['identity']}-roundtrip",
            "library": library["identity"],
            "canonical": canonical,
            "value": json.loads(canonical),
        })
    return documents


def wire_input(language, document, value):
    operation = {"id": document["id"], "value": value}
    if language == "typescript":
        operation["operation"] = "wire"
    else:
        operation["kind"] = "wire"
    return operation


def roundtrip_result(row):
    result = {"status": row.get("status")}
    for key in ("message", "error", "failure"):
        if key in row:
            result[key] = row[key]
    if "encoded" in row:
        encoded = json.dumps(
            row["encoded"], ensure_ascii=False, sort_keys=True, separators=(",", ":")
        )
        result["encoded_sha256"] = hashlib.sha256(encoded.encode()).hexdigest()
    return result


def run_profile_roundtrips(commands, languages, documents):
    counts = {}
    mismatches = []
    for language in ("lean", *languages):
        cwd = ROOT / "tools/gleam" if language == "gleam" else ROOT
        first = batch(commands[language], [
            wire_input(language, document, document["value"])
            for document in documents
        ], cwd=cwd)
        second_inputs = []
        for document, row in zip(documents, first):
            if row.get("status") != "Accepted" or row.get("encoded") != document["value"]:
                mismatches.append({
                    "classification": "profile-roundtrip",
                    "language": language,
                    "pass": 1,
                    "input": {"id": document["id"], "library": document["library"]},
                    "expected": {
                        "status": "Accepted",
                        "encoded_sha256": hashlib.sha256(
                            document["canonical"].encode()
                        ).hexdigest(),
                    },
                    "actual": roundtrip_result(row),
                })
            if "encoded" in row:
                second_inputs.append((document, wire_input(language, document, row["encoded"])))
        second = batch(commands[language], [row for _, row in second_inputs], cwd=cwd)
        for (document, _), row in zip(second_inputs, second):
            if row.get("status") != "Accepted" or row.get("encoded") != document["value"]:
                mismatches.append({
                    "classification": "profile-roundtrip",
                    "language": language,
                    "pass": 2,
                    "input": {"id": document["id"], "library": document["library"]},
                    "expected": {
                        "status": "Accepted",
                        "encoded_sha256": hashlib.sha256(
                            document["canonical"].encode()
                        ).hexdigest(),
                    },
                    "actual": roundtrip_result(row),
                })
        counts[language] = {"first": len(first), "second": len(second)}
    return counts, mismatches


def run_preset_representatives(languages):
    started = time.monotonic()
    cases = generate_preset_cases()
    sigma_rows = [sigma_case(case) for case in cases]
    sigma_cases = [row[0] for row in sigma_rows]
    with tempfile.TemporaryDirectory(prefix="ncoh-presets-") as name:
        directory = Path(name)
        commands = build_commands(languages, directory)
        execute([sys.executable, ROOT / "presets/tools/generate.py", "--check"])
        observation = json.loads(execute([sys.executable, ROOT / "tests/observation/check.py",
                                          commands["lean"][0]]))
        lean_rows = batch(commands["lean"], [adapter_input("lean", case) for case in cases])
        lean_sigma_rows = batch(commands["lean"], [adapter_input("lean", case) for case in sigma_cases])
        documents = generation_documents(cases)
        roundtrip_counts, roundtrip_mismatches = run_profile_roundtrips(
            commands, languages, documents
        )
        expected = {
            case["id"]: normalized(case["operation"], row)
            for case, row in zip(cases, lean_rows)
        }
        expected_sigma = {
            case["id"]: normalized(case["operation"], row)
            for case, row in zip(sigma_cases, lean_sigma_rows)
        }
        mismatches = list(roundtrip_mismatches)
        for case in cases:
            actual_status = expected[case["id"]]["status"]
            if actual_status != case["spec_status"]:
                mismatches.append({
                    "classification": "spec-side", "language": "lean",
                    "input": recorded_input(case),
                    "expected": {"status": case["spec_status"]}, "actual": expected[case["id"]],
                })
        for case, (_, mapping) in zip(cases, sigma_rows):
            wanted = rename_decision(expected[case["id"]], mapping)
            actual = expected_sigma["sigma-" + case["id"]]
            if actual != wanted:
                mismatches.append({
                    "classification": "renaming", "language": "lean",
                    "input": recorded_input(case),
                    "expected": wanted, "actual": actual,
                })
        counts = {}
        language_mismatches = {}
        for language in languages:
            selected = [
                case for case in cases
                if case["operation"] in SUPPORTED_OPERATIONS[language]
            ]
            selected_sigma = [
                case for case in sigma_cases
                if case["operation"] in SUPPORTED_OPERATIONS[language]
            ]
            inputs = [adapter_input(language, case) for case in selected + selected_sigma]
            if language == "rust":
                envelope_rows = batch(commands["rust_envelope"], [
                    {
                        "library": row["exchange"]["signatures"],
                        "entrypoints": row["exchange"]["entrypoints"],
                    }
                    for row in inputs
                ])
                for row, envelope in zip(inputs, envelope_rows):
                    if "exchange" in envelope:
                        row["exchange"] = envelope["exchange"]
            cwd = ROOT / "tools/gleam" if language == "gleam" else ROOT
            before = len(mismatches)
            try:
                rows = batch(commands[language], inputs, cwd=cwd)
            except RuntimeError as failure:
                counts[language] = 0
                mismatches.append({
                    "classification": "language-side", "language": language,
                    "input": [recorded_input(case) for case in selected + selected_sigma],
                    "lean": [expected[case["id"]] for case in selected]
                            + [expected_sigma[case["id"]] for case in selected_sigma],
                    "actual": {"execution_failure": str(failure)},
                })
                language_mismatches[language] = len(mismatches) - before
                continue
            counts[language] = len(rows)
            for case, row in zip(selected + selected_sigma, rows):
                actual = normalized(case["operation"], row)
                wanted = expected_sigma[case["id"]] if case["id"].startswith("sigma-") else expected[case["id"]]
                if actual != wanted:
                    mismatches.append({
                        "classification": "language-side", "language": language,
                        "input": recorded_input(case), "lean": wanted, "actual": actual,
                        "raw": row,
                    })
            language_mismatches[language] = len(mismatches) - before
        evidence = {
            "mode": "preset-representatives", "input_count": len(cases),
            "lean_decision_count": len(lean_rows),
            "preset_regeneration": "identical",
            "observation_profiles": observation,
            "language_counts": counts,
            "language_mismatch_counts": language_mismatches,
            "sigma_case_count": len(sigma_cases),
            "sigma_observation_count": len(sigma_cases) * (len(languages) + 1),
            "profile_roundtrip_document_count": len(documents),
            "profile_roundtrip_counts": roundtrip_counts,
            "profile_roundtrip_observation_count": sum(
                row["first"] + row["second"] for row in roundtrip_counts.values()
            ),
            "profile_roundtrip_expected_observation_count": (
                len(documents) * (len(languages) + 1) * 2
            ),
            "profile_roundtrip_mismatch_counts": {
                language: sum(
                    mismatch["language"] == language
                    for mismatch in roundtrip_mismatches
                )
                for language in ("lean", *languages)
            },
            "mismatch_count": len(mismatches),
            "elapsed_seconds": round(time.monotonic() - started, 3),
        }
        print(json.dumps({"evidence": evidence, "mismatches": mismatches},
                         ensure_ascii=False, sort_keys=True))
        return 1 if mismatches else 0


def run(languages, mode):
    if mode == "presets":
        return run_preset_representatives(languages)
    return run_declaration_representatives(languages)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--languages", nargs="+", choices=LANGUAGES, default=["python"])
    parser.add_argument("--mode", choices=("declarations", "presets"), default="declarations")
    arguments = parser.parse_args()
    os.environ["PYTHONPATH"] = os.pathsep.join([str(ROOT / "python/src"), str(ROOT / "tools/python/src"),
                                                os.environ.get("PYTHONPATH", "")])
    sys.path[:0] = [str(ROOT / "python/src"), str(ROOT / "tools/python/src")]
    raise SystemExit(run(arguments.languages, arguments.mode))
