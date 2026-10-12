# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def parse_range(value: str) -> tuple[int, int]:
    parts = value.strip().split("..")
    if len(parts) not in (1, 2):
        raise ValueError(f"invalid range: {value}")
    return int(parts[0], 16), int(parts[-1], 16)


def assert_sorted_disjoint(ranges: list[list], label: str) -> None:
    previous = -1
    for first, last, *_ in ranges:
        if not 0 <= first <= last <= 0x10FFFF or first <= previous:
            raise ValueError(f"invalid or overlapping {label} range: {first:x}..{last:x}")
        previous = last


def merge_adjacent(ranges: list[list]) -> list[list]:
    merged: list[list] = []
    for row in ranges:
        if merged and row[0] == merged[-1][1] + 1 and row[2:] == merged[-1][2:]:
            merged[-1][1] = row[1]
        else:
            merged.append(row.copy())
    return merged


def source_rows(root: Path, filename: str, wanted: str, fields_expected: int, property_index: int) -> list[list]:
    rows: list[list] = []
    for line in (root / filename).read_text(encoding="utf-8").splitlines():
        data = line.split("#", 1)[0].strip()
        if not data:
            continue
        fields = [field.strip() for field in data.split(";")]
        if len(fields) != fields_expected or fields[property_index] != wanted:
            continue
        first, last = parse_range(fields[0])
        rows.append([first, last, *fields[property_index + 1:]])
    rows.sort(key=lambda row: (row[0], row[1]))
    assert_sorted_disjoint(rows, wanted)
    return rows


def _source_files(manifest: dict) -> list[dict]:
    sources = manifest.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("manifest.sources must be a nonempty array")
    seen: set[str] = set()
    result: list[dict] = []
    for source in sources:
        path = source.get("path")
        if not isinstance(path, str) or Path(path).name != path or path in seen:
            raise ValueError("manifest source paths must be unique safe basenames")
        digest = source.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise ValueError(f"missing sha256 for {path}")
        seen.add(path)
        result.append(source)
    return result


def materialize(source_root: Path, manifest_path: Path) -> dict:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != "ncoh-unicode-sources@1":
        raise ValueError("unsupported Unicode source manifest schema")
    unicode_meta = manifest.get("unicode")
    if not isinstance(unicode_meta, dict) or unicode_meta.get("version") != "16.0.0":
        raise ValueError("manifest must identify Unicode 16.0.0")
    uax29_source = unicode_meta.get("uax29_source")
    if not isinstance(uax29_source, dict) or set(uax29_source) != {"repository", "revision", "path", "sha256"}:
        raise ValueError("manifest must identify the UAX #29 normative source")
    if not all(isinstance(uax29_source[key], str) and uax29_source[key] for key in uax29_source):
        raise ValueError("UAX #29 source identity fields must be nonempty strings")
    if len(uax29_source["sha256"]) != 64:
        raise ValueError("UAX #29 source identity must include a sha256 digest")
    files = _source_files(manifest)
    required = {"GraphemeBreakProperty.txt", "emoji-data.txt", "DerivedCoreProperties.txt"}
    declared = {source["path"] for source in files}
    missing = sorted(required - declared)
    if missing:
        raise ValueError(f"manifest omits consumed Unicode sources: {', '.join(missing)}")
    for source in files:
        path = source_root / source["path"]
        if not path.is_file():
            raise ValueError(f"missing Unicode source: {source['path']}")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != source["sha256"]:
            raise ValueError(f"Unicode input digest mismatch: {source['path']}")

    properties: list[list] = []
    for line in (source_root / "GraphemeBreakProperty.txt").read_text(encoding="utf-8").splitlines():
        data = line.split("#", 1)[0].strip()
        if not data:
            continue
        fields = [field.strip() for field in data.split(";")]
        if len(fields) != 2:
            raise ValueError("invalid GraphemeBreakProperty row")
        first, last = parse_range(fields[0])
        properties.append([first, last, fields[1]])
    properties.sort(key=lambda row: (row[0], row[1]))
    assert_sorted_disjoint(properties, "Grapheme_Cluster_Break")
    properties = merge_adjacent(properties)
    extended = merge_adjacent(source_rows(source_root, "emoji-data.txt", "Extended_Pictographic", 2, 1))
    extended = [[first, last] for first, last, *_ in extended]
    incb = merge_adjacent(source_rows(source_root, "DerivedCoreProperties.txt", "InCB", 3, 1))
    table = {"extended_pictographic": extended, "indic_conjunct": incb, "properties": properties}
    table_bytes = json.dumps(table, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
    return {"unicode": unicode_meta, "sources": files, "table": table, "table_bytes": table_bytes.decode(), "table_sha256": hashlib.sha256(table_bytes).hexdigest()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = materialize(args.source_root, args.source_manifest)
    text = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
