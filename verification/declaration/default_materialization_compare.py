# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from default_materialization_inputs import cases

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ("python", "typescript", "rust", "java", "gleam")
DECODES_GRAPH_WIRE_AT_RUNTIME = {"python": True, "typescript": False, "rust": True, "java": True, "gleam": True}


def execute(command, *, cwd=ROOT, data=None, env=None, timeout=600):
    result = subprocess.run([str(item) for item in command], cwd=cwd, input=data, text=True, capture_output=True, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError(json.dumps({"command": [str(item) for item in command], "stdout": result.stdout, "stderr": result.stderr}))
    return result.stdout


def observe(command, *, cwd, data, env, inputs):
    result = subprocess.run([str(item) for item in command], cwd=cwd, input=data, text=True, capture_output=True, env=env, timeout=600)
    if result.returncode:
        raise RuntimeError(json.dumps({"command": [str(item) for item in command], "stdout": result.stdout, "stderr": result.stderr}))
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    if len(rows) != len(inputs) or not all("id" in row for row in rows):
        raise RuntimeError(json.dumps({"command": [str(item) for item in command], "row_count": len(rows), "stdout": result.stdout, "stderr": result.stderr}))
    return rows


def normalized(row):
    status = row.get("status")
    if status == "Accepted":
        return {key: row[key] for key in ("id", "status", "value", "applications", "second_value", "second_applications", "input", "certificates") if key in row}
    if status == "Rejected":
        return {key: row[key] for key in ("id", "status", "type_ref", "definition_ref", "origin", "value_path", "condition", "observed", "reference_trace")}
    if status == "Wire":
        return {key: row.get(key) for key in ("id", "status", "classification", "path")}
    if status in ("CertificateMismatch", "Unresolved"):
        return row
    return {"id": row.get("id"), "status": "AdapterFailure", "row": row}


def untyped(row):
    return row.get("status") == "Wire" and not (isinstance(row.get("classification"), str) and isinstance(row.get("path"), str))


def differs(actual, wanted):
    return actual != wanted or untyped(actual) or untyped(wanted)


def out_of_scope(language, expected):
    return not DECODES_GRAPH_WIRE_AT_RUNTIME[language] and expected.get("status") == "Wire"


def compare(inputs, outputs, languages):
    mismatches = []
    compared = {}
    excluded = {}
    for language in languages:
        compared[language] = 0
        excluded[language] = 0
        for case, expected, actual in zip(inputs, outputs["lean"], outputs[language]):
            if out_of_scope(language, expected):
                excluded[language] += 1
                continue
            compared[language] += 1
            if differs(actual, expected):
                mismatches.append({"language": language, "id": case["id"], "lean": expected, "actual": actual})
    return mismatches, compared, excluded


def prepare(language, directory, commands):
    if language == "typescript":
        if not (ROOT / "packages/typescript/adapter/node_modules").exists(): execute(["npm", "ci"], cwd=ROOT / "packages/typescript/adapter")
        execute(["npm", "run", "build"], cwd=ROOT / "packages/typescript/adapter")
        commands["typescript"] = ["node", ROOT / "verification/declaration/default_materialization_typescript.mjs"]
    if language == "rust":
        output = execute(["cargo", "build", "--manifest-path", ROOT / "verification/rust/Cargo.toml", "--example", "default_materialization_compare", "--message-format=json"])
        records = [json.loads(line) for line in output.splitlines()]
        commands["rust"] = [next(row["executable"] for row in records if row.get("target", {}).get("name") == "default_materialization_compare" and row.get("executable"))]
    if language == "java":
        classes = directory / "java"
        classes.mkdir()
        sources = sorted((ROOT / "packages/java/adapter/src/main/java").rglob("*.java"))
        sources.append(ROOT / "verification/declaration/DefaultMaterializationCompare.java")
        execute(["javac", "--release", "21", "-sourcepath", os.pathsep.join((os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"])), "-d", classes, *sources])
        commands["java"] = ["java", "-cp", classes, "DefaultMaterializationCompare"]


def run(languages):
    inputs = cases()
    data = "".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in inputs)
    environment = {**os.environ, "PYTHONPATH": os.pathsep.join([str(ROOT / "packages/python/adapter/src"), os.environ.get("PYTHONPATH", "")])}
    execute(["lake", "build", "NecoherenceVerification"], cwd=ROOT / "verification/lean")
    commands = {"lean": ["lake", "env", "lean", "--run", ROOT / "verification/lean/DefaultMaterializationCompare.lean"], "python": [sys.executable, ROOT / "verification/declaration/default_materialization_python.py"], "gleam": ["gleam", "run", "--no-print-progress", "-m", "default_materialization_compare"]}
    failures = []
    with tempfile.TemporaryDirectory(prefix="default-comparison-") as directory:
        directory = Path(directory)
        active = []
        for language in languages:
            try:
                prepare(language, directory, commands)
                active.append(language)
            except RuntimeError as failure:
                failures.append({"classification": "language-side", "language": language, "execution_failure": str(failure)})
        outputs = {}
        for language in ("lean", *active):
            cwd = ROOT / "verification/lean" if language == "lean" else ROOT / "verification/declaration/default_materialization_gleam" if language == "gleam" else ROOT
            try:
                rows = [normalized(row) for row in observe(commands[language], cwd=cwd, data=data, env=environment, inputs=inputs)]
                if [row["id"] for row in rows] != [item["id"] for item in inputs]:
                    raise RuntimeError(json.dumps({"language": language, "row_count": len(rows), "rows": rows}))
            except RuntimeError as failure:
                if language == "lean":
                    raise
                failures.append({"classification": "language-side", "language": language, "execution_failure": str(failure)})
                continue
            outputs[language] = rows
        compared = [language for language in active if language in outputs]
        found, counted, excluded = compare(inputs, outputs, compared)
        mismatches = failures + found
        assert all(counted[language] + excluded[language] == len(inputs) for language in compared)
        for case, result in zip(inputs, outputs["lean"]):
            if result["status"] == "Accepted" and (result["value"] != result["second_value"] or result["second_applications"] or result["input"] != case["before"] or case["tamper"] and result["certificates"] != [False] * 4):
                raise RuntimeError(json.dumps({"law_failure": case["id"], "result": result}))
        print(json.dumps({"cases": len(inputs), "languages": list(languages), "comparisons": sum(counted.values()), "compared_by_language": counted, "excluded_wire_by_language": excluded, "inputs_per_language": len(inputs), "oracle": "live Lean materializeDefaults", "mismatches": mismatches}, ensure_ascii=False, sort_keys=True))
        return 1 if mismatches else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--languages", nargs="+", choices=LANGUAGES, default=list(LANGUAGES))
    parser.add_argument("--bounded", action="store_true", required=True)
    arguments = parser.parse_args()
    raise SystemExit(run(arguments.languages))
