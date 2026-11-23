# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

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

from semantic_invariant_inputs import NumberText, generate, wire_cases
from preset_representative_inputs import generate_preset_cases, rename_decision, sigma_case

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ("python", "typescript", "rust", "java", "gleam")
RUNTIME_OPERATIONS = {"profile", "library", "value", "classification", "wire"}
SUPPORTED_OPERATIONS = {
    "python": RUNTIME_OPERATIONS | {"residual_record"},
    "typescript": RUNTIME_OPERATIONS | {"residual_record"},
    "java": RUNTIME_OPERATIONS | {"residual_record"},
    "gleam": (RUNTIME_OPERATIONS - {"classification"}) | {"residual_record"},
    "rust": {"profile", "library", "value", "inclusion", "samples", "classification", "residual_record"},
}
RUST_REFERENCE_OPERATIONS = {"residual_record"}


CLASSIFICATION_WIRE_NOT_DECODED_AT_RUNTIME = {
    "python": set(),
    "typescript": {"composition", "value", "semantic"},
    "rust": set(),
    "java": {"composition"},
    "gleam": set(),
}


def classification_domain(case):
    if case.get("domain") == "composition":
        return "composition"
    return "value" if case.get("entry") == "value" else "semantic"


def out_of_scope(language, case, expected):
    return (case["operation"] == "classification" and expected.get("failure_kind") == "Wire"
            and classification_domain(case) in CLASSIFICATION_WIRE_NOT_DECODED_AT_RUNTIME[language])


def execute(command, *, cwd=ROOT, input_text=None, env=None, timeout=1200):
    result = subprocess.run([str(item) for item in command], cwd=cwd, text=True,
                            input=input_text, capture_output=True, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError(json.dumps({"command": [str(item) for item in command],
                                       "stdout": result.stdout, "stderr": result.stderr}, ensure_ascii=False))
    return result.stdout


def json_line(value):
    literals = []

    def token(item):
        if isinstance(item, NumberText):
            literals.append(str(item))
            return f"__number_text_{len(literals) - 1}__"
        if isinstance(item, dict):
            return {key: token(child) for key, child in item.items()}
        if isinstance(item, list):
            return [token(child) for child in item]
        return item

    text = json.dumps(token(value), ensure_ascii=False, separators=(",", ":"))
    for index, literal in enumerate(literals):
        text = text.replace(f'"__number_text_{index}__"', literal)
    return text


def batch(command, cases, *, cwd=ROOT, env=None):
    if not cases:
        return []
    text = "".join(json_line(case) + "\n" for case in cases)
    output = execute(command, cwd=cwd, input_text=text, env=env)
    rows = [json.loads(line) for line in output.splitlines() if line.strip()]
    if len(rows) != len(cases):
        raise RuntimeError(json.dumps({"kind": "AdapterRowCount", "expected": len(cases),
                                       "actual": len(rows), "output": output}, ensure_ascii=False))
    return rows


NUMBER_SPELLING = re.compile(r"(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?)([0-9]+))?")


EXPONENT_LIMIT_DIGITS = "10000"


class ExponentAtLimit(ValueError):
    pass


def exponent_digits_at_limit(power):
    significant = power.lstrip("0")
    return len(significant) > len(EXPONENT_LIMIT_DIGITS) or (
        len(significant) == len(EXPONENT_LIMIT_DIGITS) and significant >= EXPONENT_LIMIT_DIGITS)


def exact_number(text):
    sign, whole, fraction, marker, power = NUMBER_SPELLING.fullmatch(text).groups()
    if power is not None and exponent_digits_at_limit(power):
        raise ExponentAtLimit(text[:40])
    fraction = fraction or ""
    digits = whole + fraction
    exponent = len(fraction)
    if power is not None:
        count = int(power)
        if marker == "-":
            exponent += count
        elif count >= exponent:
            digits += "0" * (count - exponent)
            exponent = 0
        else:
            exponent -= count
    if exponent:
        return {"tag": "Decimal", "text": text}
    digits = digits.lstrip("0") or "0"
    return {"tag": "Integer", "value": "-" + digits if sign and digits != "0" else digits}


def exact_json(value):
    if isinstance(value, NumberText):
        return exact_number(str(value))
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
    if operation == "classification":
        if language != "typescript":
            common["kind"] = common.pop("operation")
        return common
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
        entrypoints = [{"identity": row["wire_identity"], "definition": row["id"]}
                       for row in library["definitions"]]
        common["exchange"] = {
            "schema": "ncoh-checked-generation@5",
            "basis": signature_basis(library, entrypoints),
            "signatures": exchange_library,
            "composition": None,
            "entrypoints": entrypoints,
        }
        common["kind"] = "admit" if operation in ("profile", "library") else operation
        if operation in ("value", "residual_record"):
            common["value"] = exact_json(common["value"])
        common.pop("operation", None)
        return common
    if language == "typescript":
        if operation in ("value", "residual_record"):
            common["value"] = exact_json(common["value"])
        return common
    if language == "python":
        common["kind"] = operation
        common.pop("operation", None)
        if operation == "profile":
            common["profile"] = common["library"]["profile"]
        return common
    if language in ("java", "gleam"):
        common["kind"] = operation
        common.pop("operation", None)
        if language == "java" and operation in ("profile", "library"):
            common["kind"] = "profile_admission"
        return common
    raise ValueError(language)


def wire_rejection(row):
    if row.get("failure_kind") == "Wire":
        return {"classification": row.get("classification"), "path": row.get("path")}
    failure = row.get("failure")
    if isinstance(failure, dict) and failure.get("kind") == "Wire":
        return {"classification": failure.get("classification"), "path": failure.get("path")}
    return None


def untyped(row):
    return row.get("failure_kind") == "Wire" and not (isinstance(row.get("classification"), str) and isinstance(row.get("path"), str))


def differs(actual, wanted):
    return actual != wanted or untyped(actual) or untyped(wanted)


def canonical_exact(value):
    if value["tag"] == "Object":
        members = sorted(({"key": member["key"], "value": canonical_exact(member["value"])} for member in value["members"]), key=lambda member: member["key"])
        return {"tag": "Object", "members": members}
    if value["tag"] == "Array":
        return {"tag": "Array", "items": [canonical_exact(item) for item in value["items"]]}
    return value

def normalized(operation, row):
    if operation == "classification":
        wire = wire_rejection(row)
        if wire is not None:
            return {"status": row.get("status"), "failure_kind": "Wire", **wire}
        return {key: row.get(key) for key in ("status", "classification", "obligations", "residuals", "stops", "failures", "provenance")}
    failure = row.get("failure", {})
    status = row.get("status") or row.get("classification")
    condition = row.get("condition", failure.get("condition"))
    if isinstance(condition, dict):
        condition = condition["tag"] + (":" + str(condition["value"]) if "value" in condition else "")
    if isinstance(condition, str):
        match = re.fullmatch(r'(\w+)\("([^"]*)"\)', condition)
        if match:
            condition = f"{match.group(1)}:{match.group(2)}"
    if isinstance(status, str):
        status = status[:1].upper() + status[1:].lower()
    if operation in ("profile", "library"):
        predicate = row.get("predicate", failure.get("predicate"))
        path = row.get("path", failure.get("location", []))
        return {"status": status, "predicate": predicate, "path": path}
    if operation == "value":
        return {"status": status, "type_ref": row.get("type_ref", failure.get("type_ref")),
                "condition": condition, "path": row.get("path", failure.get("path", [])),
                "trace": row.get("trace", failure.get("trace", []))}
    if operation == "inclusion":
        return {"status": status}
    if operation == "residual_record":
        return {"status": row.get("status"), "bytes": row.get("bytes"), "message": row.get("message")}
    if operation == "samples":
        values = row.get("values", [])
        return {"status": status, "sample_bound": row.get("sample_bound"),
                "sample_count": len(values), "values": [canonical_exact(value) for value in values]}
    if operation == "wire":
        wire = wire_rejection(row)
        typed = {"failure_kind": "Wire", **wire} if wire is not None else {"failure_kind": None, "classification": None, "path": None}
        return {"status": status, "encoded": row.get("encoded"), **typed}
    raise ValueError(operation)

def mismatch_classification(case):
    return {"classification": "language-side"}


def build_commands(languages, directory):
    lean_dir = ROOT / "verification/lean"
    execute(["lake", "build", "semantic_invariant"], cwd=lean_dir)
    lean_launcher = directory / "lean_runner"
    lean_launcher.write_text("#!/bin/sh\ncd " + shlex.quote(str(lean_dir)) + " || exit\nexec lake exe semantic_invariant \"$@\"\n", encoding="utf-8")
    lean_launcher.chmod(0o700)
    commands = {"lean": [lean_launcher]}
    adapters = ROOT / "verification/declaration"
    if "python" in languages:
        commands["python"] = [sys.executable, adapters / "python/semantic_invariant_adapter.py"]
    if "typescript" in languages:
        package = ROOT / "packages/typescript/adapter"
        if not (package / "node_modules").exists():
            execute(["npm", "ci"], cwd=package)
        execute(["npm", "run", "build"], cwd=package)
        commands["typescript"] = ["node", adapters / "typescript/semantic_invariant_adapter.mjs"]
    if "java" in languages:
        classes = directory / "java"
        classes.mkdir()
        sources = sorted((ROOT / "packages/java/adapter/src/main/java").rglob("*.java"))
        sources.append(adapters / "java/SemanticInvariantAdapter.java")
        execute(["javac", "-sourcepath", os.pathsep.join((os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"])), "-d", classes, *sources])
        commands["java"] = ["java", "-cp", classes, "necoherence.comparison.SemanticInvariantAdapter"]
    if "gleam" in languages:
        execute(["gleam", "build", "--no-print-progress"], cwd=adapters / "gleam_driver")
        commands["gleam"] = ["gleam", "run", "--no-print-progress", "-m", "semantic_invariant_runner"]
    if "rust" in languages:
        envelope_output = execute([
            "cargo", "build", "--manifest-path",
            ROOT / "verification/declaration/signature_generator/Cargo.toml",
            "--bin", "rust_generation_envelope", "--message-format=json",
        ], env={**os.environ, "CARGO_TARGET_DIR": str(directory / "cargo")})
        commands["rust_envelope"] = [next(
            json.loads(line)["executable"] for line in envelope_output.splitlines()
            if json.loads(line).get("target", {}).get("name") == "rust_generation_envelope"
            and json.loads(line).get("executable")
        )]
        output = execute(["cargo", "build", "--manifest-path", ROOT / "verification/rust/Cargo.toml",
                          "--example", "semantic_invariant_adapter", "--message-format=json"],
                         env={**os.environ, "CARGO_TARGET_DIR": str(directory / "cargo")})
        commands["rust"] = [next(json.loads(line)["executable"] for line in output.splitlines()
                                 if json.loads(line).get("executable"))]
    return commands


def with_rust_envelopes(commands, inputs):
    generation_inputs = [row for row in inputs if "exchange" in row]
    envelope_rows = batch(commands["rust_envelope"], [
        {
            "library": row["exchange"]["signatures"],
            "entrypoints": row["exchange"]["entrypoints"],
        }
        for row in generation_inputs
    ])
    for row, envelope in zip(generation_inputs, envelope_rows):
        if "exchange" in envelope:
            row["exchange"] = envelope["exchange"]
    return inputs


def residual_reasons(encoded_bytes):
    record = json.loads(bytes.fromhex(encoded_bytes))
    return {json.dumps(item["reason"], sort_keys=True, ensure_ascii=False) for item in record["residuals"]}


def check_residual_records(commands, languages, cases, reference_rows, language_rows, mismatches):
    by_id = {case["id"]: case for case in cases}
    sources = {"rust": dict(zip(by_id, reference_rows))}
    for language in languages:
        if language != "rust" and "residual_record" in SUPPORTED_OPERATIONS[language]:
            sources[language] = language_rows.get(language, {})
    decoded = {}
    for language, rows in sources.items():
        encoded = {identity: row for identity, row in rows.items() if row.get("status") == "encoded"}
        decoded[language] = dict(zip(encoded, batch(commands["rust"], [
            {"id": identity, "kind": "residual_record_decode", "bytes": row["bytes"]}
            for identity, row in encoded.items()])))
    reasons = set()
    for identity, row in sources["rust"].items():
        case = by_id[identity]
        if row.get("status") not in ("encoded", "not-unresolved"):
            mismatches.append({"classification": "language-side", "language": "rust",
                               "input": {"id": identity}, "lean": None, "actual": row})
        if row.get("status") == "encoded":
            reasons |= residual_reasons(row["bytes"])
            own = decoded["rust"].get(identity, {})
            wanted_input = {"value": exact_json(case["value"])}
            if (own.get("status") != "decoded" or own.get("basis") != case["basis"]
                    or own["input"]["value"] != wanted_input["value"]
                    or own["obligation_count"] != len(json.loads(bytes.fromhex(row["bytes"]))["residuals"])):
                mismatches.append({"classification": "language-side", "language": "rust",
                                   "input": {"id": identity}, "lean": None, "actual": own})
    for language, rows in sources.items():
        for identity, row in decoded[language].items():
            if differs(row, decoded["rust"].get(identity)):
                mismatches.append({"classification": "language-side", "language": language,
                                   "input": {"id": identity}, "lean": decoded["rust"].get(identity), "actual": row})
    encoded_count = sum(row.get("status") == "encoded" for row in sources["rust"].values())
    if cases and encoded_count == 0:
        mismatches.append({"classification": "language-side", "language": "rust",
                           "input": {"operation": "residual_record"}, "lean": None,
                           "actual": {"encoded_count": 0}})
    return {"input_count": len(cases), "encoded_count": encoded_count,
            "not_unresolved_count": sum(row.get("status") == "not-unresolved" for row in sources["rust"].values()),
            "decode_counts": {language: len(rows) for language, rows in decoded.items()},
            "reasons": sorted(reasons)}


def run_declaration_representatives(languages):
    started = time.monotonic()
    cases = generate()
    needs_rust = any("residual_record" in SUPPORTED_OPERATIONS[language] for language in languages)
    with tempfile.TemporaryDirectory(prefix="ncoh-declarations-") as name:
        directory = Path(name)
        commands = build_commands(list(languages) + (["rust"] if needs_rust and "rust" not in languages else []), directory)
        lean_cases = [case for case in cases if case["operation"] not in RUST_REFERENCE_OPERATIONS]
        lean_inputs = [adapter_input("lean", case) for case in lean_cases]
        lean_rows = batch(commands["lean"], lean_inputs)
        expected = {case["id"]: normalized(case["operation"], row) for case, row in zip(lean_cases, lean_rows)}
        reference_cases = [case for case in cases if case["operation"] in RUST_REFERENCE_OPERATIONS] if needs_rust else []
        reference_rows = batch(commands["rust"], with_rust_envelopes(
            commands, [adapter_input("rust", case) for case in reference_cases]))
        expected.update({case["id"]: normalized(case["operation"], row)
                         for case, row in zip(reference_cases, reference_rows)})
        mismatches = []
        counts = {}
        language_rows = {}
        excluded = {language: 0 for language in languages}
        for language in languages:
            selected = [case for case in cases if case["operation"] in SUPPORTED_OPERATIONS[language]
                        and not (language == "rust" and case["operation"] in RUST_REFERENCE_OPERATIONS)]
            inputs = [adapter_input(language, case) for case in selected]
            if language == "rust":
                with_rust_envelopes(commands, inputs)
            cwd = ROOT / "verification/declaration/gleam_driver" if language == "gleam" else ROOT
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
            language_rows[language] = {case["id"]: row for case, row in zip(selected, rows)}
            for case, row in zip(selected, rows):
                if out_of_scope(language, case, expected[case["id"]]):
                    excluded[language] += 1
                    continue
                actual = normalized(case["operation"], row)
                if differs(actual, expected[case["id"]]):
                    mismatches.append({**mismatch_classification(case), "language": language,
                                       "input": case, "lean": expected[case["id"]], "actual": actual})
        from necoherence.type_signatures import signature_basis
        wires = wire_cases(signature_basis)
        lean_wire = batch(commands["lean"], [adapter_input("lean", case) for case in wires])
        for language in languages:
            if "wire" not in SUPPORTED_OPERATIONS[language]:
                continue
            language_wire = batch(commands[language], [adapter_input(language, case) for case in wires],
                                  cwd=ROOT / "verification/declaration/gleam_driver" if language == "gleam" else ROOT)
            for case, lean_row, row in zip(wires, lean_wire, language_wire):
                wanted = normalized("wire", lean_row)
                actual = normalized("wire", row)
                if differs(actual, wanted):
                    mismatches.append({**mismatch_classification(case), "language": language,
                                       "input": case, "lean": wanted, "actual": actual})
            counts[language] += len(wires)
        residual_evidence = (check_residual_records(commands, languages, reference_cases, reference_rows,
                                                    language_rows, mismatches) if needs_rust else None)
        evidence = {"mode": "declaration-representatives", "input_count": len(cases),
                    "residual_record": residual_evidence,
                    "language_counts": counts,
                    "excluded_wire_classification": excluded,
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
            "schema": "ncoh-checked-generation@5",
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
        cwd = ROOT / "verification/declaration/gleam_driver" if language == "gleam" else ROOT
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
        execute([sys.executable, ROOT / "verification/presets/tools/generate.py", "--check"])
        observation = json.loads(execute([sys.executable, ROOT / "verification/observation/check.py",
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
            if differs(actual, wanted):
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
            cwd = ROOT / "verification/declaration/gleam_driver" if language == "gleam" else ROOT
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
                if out_of_scope(language, case, wanted):
                    continue
                if differs(actual, wanted):
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
    parser.add_argument("--languages", nargs="+", choices=LANGUAGES, default=list(LANGUAGES))
    parser.add_argument("--mode", choices=("declarations", "presets"), default="declarations")
    arguments = parser.parse_args()
    os.environ["PYTHONPATH"] = os.pathsep.join([str(ROOT / "packages/python/adapter/src"), os.environ.get("PYTHONPATH", "")])
    sys.path[:0] = [str(ROOT / "packages/python/adapter/src")]
    raise SystemExit(run(arguments.languages, arguments.mode))
