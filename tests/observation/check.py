# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from profiles import json_schema_library, protobuf_library


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RUNNER = ROOT / "tools/lean/.lake/build/bin/semantic_invariant"


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def exchange(library: dict[str, Any]) -> dict[str, Any]:
    digest = "0" * 64
    return {
        "schema": "ncoh-checked-generation@4",
        "basis": {
            "signature_schema": library["schema"],
            "library_identity": library["identity"],
            "library_revision": library["revision"],
            "profile": library["profile"]["reference"],
            "graph_sha256": digest,
            "provenance_sha256": digest,
            "metadata_sha256": digest,
            "problem_sha256": None,
            "entrypoints_sha256": digest,
        },
        "signatures": library,
        "composition": None,
        "entrypoints": [{"identity": "Root", "definition": "root"}],
    }


def requests() -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    libraries = {
        "json-schema": json_schema_library(),
        "protobuf": protobuf_library(),
    }
    rows: list[dict[str, Any]] = []
    exchanges: dict[str, dict[str, Any]] = {}
    for name, subject in libraries.items():
        rows.extend(
            [
                {"id": f"{name}-profile", "kind": "profile", "library": subject},
                {"id": f"{name}-library", "kind": "library", "library": subject},
                {"id": f"{name}-admission", "kind": "profile_admission", "library": subject},
            ]
        )
        exchanges[name] = exchange(subject)
        rows.append({"id": f"{name}-wire", "kind": "wire", "value": exchanges[name]})
    return rows, exchanges


def invoke(runner: Path, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    input_text = "".join(canonical_json(row) + "\n" for row in rows)
    completed = subprocess.run(
        [runner], input=input_text, capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr)
    return [json.loads(line) for line in completed.stdout.splitlines() if line]


def check(runner: Path = DEFAULT_RUNNER) -> dict[str, Any]:
    rows, exchanges = requests()
    observed = invoke(runner, rows)
    by_id = {row["id"]: row for row in observed}
    for row in rows:
        result = by_id[row["id"]]
        if result["status"] != "Accepted":
            raise AssertionError(result)
    for name, original in exchanges.items():
        encoded = by_id[f"{name}-wire"]["encoded"]
        if canonical_json(encoded) != canonical_json(original):
            raise AssertionError(f"{name}: encode(decode(j)) != j")
        second = invoke(
            runner,
            [{"id": f"{name}-wire-second", "kind": "wire", "value": encoded}],
        )[0]["encoded"]
        if canonical_json(second) != canonical_json(encoded):
            raise AssertionError(f"{name}: decode(encode(x)) != x")
    return {
        "profiles": sorted(exchanges),
        "profile_checks": 2,
        "library_checks": 2,
        "admissions": 2,
        "roundtrips": 4,
    }


def main() -> int:
    runner = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RUNNER
    print(canonical_json(check(runner)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
