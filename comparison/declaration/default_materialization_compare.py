# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

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


def execute(command, *, cwd=ROOT, data=None, env=None, timeout=600):
    result = subprocess.run([str(item) for item in command], cwd=cwd, input=data, text=True, capture_output=True, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError(json.dumps({"command": [str(item) for item in command], "stdout": result.stdout, "stderr": result.stderr}))
    return result.stdout


def normalized(row):
    status = row.get("status")
    if status == "Accepted":
        return {key: row[key] for key in ("id", "status", "value", "applications", "second_value", "second_applications", "input", "certificates") if key in row}
    if status == "Rejected":
        condition = row["condition"]
        if isinstance(condition, dict): condition = condition["tag"] + (":" + str(condition["value"]) if "value" in condition else "")
        return {"id": row["id"], "status": status, "type_ref": row["type_ref"], "origin": row["origin"], "value_path": row["value_path"], "condition": condition, "reference_trace": row["reference_trace"]}
    if status in ("Wire", "CertificateMismatch", "Unresolved"):
        return row
    raise RuntimeError(json.dumps({"adapter_output": row}))


def run(languages):
    inputs = cases()
    data = "".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in inputs)
    environment = {**os.environ, "PYTHONPATH": os.pathsep.join([str(ROOT / "python/src"), os.environ.get("PYTHONPATH", "")])}
    execute(["lake", "build", "NecoherenceTools"], cwd=ROOT / "tools/lean")
    commands = {"lean": ["lake", "env", "lean", "--run", ROOT / "tools/lean/DefaultMaterializationCompare.lean"], "python": [sys.executable, ROOT / "comparison/declaration/default_materialization_python.py"], "gleam": ["gleam", "run", "--no-print-progress", "-m", "default_materialization_compare"]}
    with tempfile.TemporaryDirectory(prefix="default-comparison-") as directory:
        directory = Path(directory)
        if "typescript" in languages:
            if not (ROOT / "typescript/node_modules").exists(): execute(["npm", "ci"], cwd=ROOT / "typescript")
            execute(["npm", "run", "build"], cwd=ROOT / "typescript")
            commands["typescript"] = ["node", ROOT / "comparison/declaration/default_materialization_typescript.mjs"]
        if "rust" in languages:
            output = execute(["cargo", "build", "--manifest-path", ROOT / "tools/rust/Cargo.toml", "--example", "default_materialization_compare", "--message-format=json"], env={**os.environ, "CARGO_TARGET_DIR": str(ROOT / "rust/target")})
            records = [json.loads(line) for line in output.splitlines()]
            commands["rust"] = [next(row["executable"] for row in records if row.get("target", {}).get("name") == "default_materialization_compare" and row.get("executable"))]
        if "java" in languages:
            classes = directory / "java"
            classes.mkdir()
            sources = sorted((ROOT / "java/src/main/java").rglob("*.java"))
            sources.append(ROOT / "comparison/declaration/DefaultMaterializationCompare.java")
            execute(["javac", "--release", "21", "-d", classes, *sources])
            commands["java"] = ["java", "-cp", classes, "DefaultMaterializationCompare"]
        outputs = {}
        for language in ("lean", *languages):
            cwd = ROOT / "tools/lean" if language == "lean" else ROOT / "tools/gleam" if language == "gleam" else ROOT
            output = execute(commands[language], cwd=cwd, data=data, env=environment)
            rows = [normalized(json.loads(line)) for line in output.splitlines() if line.strip()]
            if len(rows) != len(inputs) or [row["id"] for row in rows] != [item["id"] for item in inputs]:
                raise RuntimeError(json.dumps({"language": language, "row_count": len(rows), "rows": rows}))
            outputs[language] = rows
        mismatches = []
        for language in languages:
            for case, expected, actual in zip(inputs, outputs["lean"], outputs[language]):
                if actual != expected: mismatches.append({"language": language, "id": case["id"], "lean": expected, "actual": actual})
        for case, result in zip(inputs, outputs["lean"]):
            if result["status"] == "Accepted" and (result["value"] != result["second_value"] or result["second_applications"] or result["input"] != case["before"] or case["tamper"] and result["certificates"] != [False] * 4):
                raise RuntimeError(json.dumps({"law_failure": case["id"], "result": result}))
        print(json.dumps({"cases": len(inputs), "languages": list(languages), "comparisons": len(inputs) * len(languages), "oracle": "live Lean materializeDefaults", "mismatches": mismatches}, ensure_ascii=False, sort_keys=True))
        return 1 if mismatches else 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--languages", nargs="+", choices=LANGUAGES, default=list(LANGUAGES))
    parser.add_argument("--bounded", action="store_true", required=True)
    arguments = parser.parse_args()
    raise SystemExit(run(arguments.languages))
