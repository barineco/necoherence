# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Per-operation cost of the Java state families.

For each operation, s(n) is the cost of k = n operations on a state that holds n entries, divided by k.
Two quantities are counted in one JVM run with -Xint:

* the jump instructions that the classes under necoherence/ execute (an ASM 9.7.1 agent counts them);
* the bytes that the thread allocates (ThreadMXBean.getThreadAllocatedBytes).

The check requires s(10n) <= 2 * s(n) for n = 1000 in both quantities. sv_validate_value validates one value on a
prepared value over a graph of n nodes (the preparation is outside the counted region); its jump count must also be
equal for n and 10n. The jump count must also agree across
repeated runs; the allocated bytes must agree within one percent. reconcile_linear reads its whole input once
per call, so the check requires only that s(10n) <= 12 * s(n).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

from .implementations import ImplementationError, java_tool

ROOT = Path(__file__).resolve().parents[2]
GUEST = Path(__file__).resolve().parent / "java_cost"
ADAPTER = ROOT / "packages/java/adapter"
ASM_URL = "https://repo1.maven.org/maven2/org/ow2/asm/asm/9.7.1/asm-9.7.1.jar"
ASM_SHA256 = "8cadd43ac5eb6d09de05faecca38b917a040bb9139c7edeb4cc81c740b713281"
OPERATIONS = [
    "core_lookup",
    "core_bump",
    "core_apply",
    "core_apply_conflicted",
    "core_apply_unknown",
    "store_observe",
    "store_apply",
    "reconcile_linear",
    "rp_submit_fifo",
    "rp_submit_latest_wins",
    "rp_decide_start",
    "rp_decide_start_blocked",
    "rp_apply_start_observation",
    "rp_apply_completion_observation",
    "rp_decide_cancel",
    "rp_derive_pending",
    "rp_derive_in_flight",
    "rp_derive_concurrent",
    "ne_prepare",
    "ne_send_command",
    "ne_observe_start",
    "ne_cancel_command",
    "ne_observe_pending",
    "ne_observe_delivered",
    "ne_observe_late",
    "ne_annotate_effect",
    "ne_retry",
    "ne_read_network_state",
    "file_effect_read",
    "file_effect_replace",
    "da_admit_submitted",
    "da_admit_executed",
    "da_elide_admission_provenance",
    "file_effect_track",
    "sv_validate_value",
]
LINEAR_OPERATIONS = {"reconcile_linear"}
EXACT_OPERATIONS = {"sv_validate_value"}
BASE_COUNT = 1000
GROWTH = 10
RATIO_LIMIT = 2.0
LINEAR_RATIO_LIMIT = 12.0
BYTES_SPREAD_LIMIT = 0.01
RUN_TIMEOUT = 150


def run_tool(command: list[str], cwd: Path) -> str:
    process = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if process.returncode != 0:
        raise ImplementationError(f"{' '.join(command[:2])} failed:\n{process.stdout}{process.stderr}")
    return process.stdout


def fetch_asm(directory: Path) -> Path:
    jar = directory / "asm-9.7.1.jar"
    local = os.environ.get("NCOH_ASM_JAR")
    if local:
        shutil.copyfile(local, jar)
    else:
        with urllib.request.urlopen(ASM_URL, timeout=60) as response:
            jar.write_bytes(response.read())
    digest = hashlib.sha256(jar.read_bytes()).hexdigest()
    if digest != ASM_SHA256:
        raise ImplementationError(f"asm-9.7.1.jar has sha256 {digest}, expected {ASM_SHA256}")
    return jar


def build_agent(directory: Path, asm: Path) -> Path:
    classes = directory / "agent-classes"
    classes.mkdir()
    sources = sorted(str(path) for path in (GUEST / "ncohagent").glob("*.java"))
    run_tool([java_tool("javac"), "--release", "21", "-cp", str(asm), "-d", str(classes), *sources], directory)
    run_tool([java_tool("jar"), "xf", str(asm), "org"], classes)
    manifest = directory / "manifest.txt"
    manifest.write_text("Premain-Class: ncohagent.Agent\n")
    jar = directory / "ncohagent.jar"
    run_tool([java_tool("jar"), "cfm", str(jar), str(manifest), "-C", str(classes), "."], directory)
    return jar


def build_classes(directory: Path, agent: Path) -> Path:
    classes = directory / "classes"
    classes.mkdir()
    sources = sorted(str(path) for path in (ADAPTER / "src/main/java").rglob("*.java"))
    sources.append(str(GUEST / "JavaCost.java"))
    run_tool(
        [java_tool("javac"), "--release", "21", "-cp", str(agent), "-sourcepath", os.pathsep.join((os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"])),
         "-d", str(classes), *sources],
        directory,
    )
    return classes


def measure(
    classes: Path, agent: Path, operation: str, count: int, limits: tuple[int, int] | None = None
) -> dict[str, int] | None:
    bounds = [str(limit) for limit in limits] if limits else []
    try:
        process = subprocess.run(
            [java_tool("java"), "-Xint", "-XX:+UseSerialGC", f"-javaagent:{agent}", "-cp", f"{classes}{os.pathsep}{agent}",
             "JavaCost", operation, str(count), *bounds],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return None
    if process.returncode != 0:
        raise ImplementationError(f"JavaCost {operation} {count} failed:\n{process.stderr[-2000:]}")
    return json.loads(process.stdout.strip().splitlines()[-1])


SEMANTIC = "necoherence/semantic/"
TABLE_BUILDERS = [
    f"{SEMANTIC}ValidationTables.<init>",
    f"{SEMANTIC}ValidationTables.formatIndex",
    f"{SEMANTIC}ValidationTables.domainIndex",
    f"{SEMANTIC}ValidationTables.graphemeTableOf",
    f"{SEMANTIC}ValidationTables.programOf",
    f"{SEMANTIC}ValidationTables.sealedKeysOf",
    f"{SEMANTIC}ValidationTables.fieldNamesOf",
    f"{SEMANTIC}ValidationTables.fieldsOf",
    f"{SEMANTIC}ValidationTables.enumSet",
]
MEANING_COMPUTATION = f"{SEMANTIC}SemanticValidation.computeMeaning"
VALIDATION_ENTRY = f"{SEMANTIC}SemanticValidation.validateValue:(L{SEMANTIC}ValidationTables;"


def check_prepared(classes: Path, agent: Path) -> list[str]:
    specs = [*TABLE_BUILDERS, MEANING_COMPUTATION, VALIDATION_ENTRY]
    process = subprocess.run(
        [java_tool("java"), "-Xint", "-XX:+UseSerialGC", f"-javaagent:{agent}={','.join(specs)}", "-cp", f"{classes}{os.pathsep}{agent}",
         "JavaCost", "sv_prepared_once", "0"],
        capture_output=True, text=True, timeout=RUN_TIMEOUT,
    )
    if process.returncode != 0:
        raise ImplementationError(f"JavaCost sv_prepared_once failed:\n{process.stderr[-2000:]}")
    phases = json.loads(process.stdout.strip().splitlines()[-1])["phases"]
    failures: list[str] = []
    totals = {spec: 0 for spec in specs}
    for phase in phases:
        counts = phase["counts"]
        for spec in specs:
            totals[spec] += counts[spec]
        if phase["build"]:
            failures += [f"{phase['label']}: {spec} was called {counts[spec]} times, expected at least 1" for spec in TABLE_BUILDERS if counts[spec] < 1]
        else:
            failures += [f"{phase['label']}: {spec} was called {counts[spec]} times, expected 0" for spec in TABLE_BUILDERS if counts[spec] != 0]
        if counts[MEANING_COMPUTATION] != phase["meaning"]:
            failures.append(f"{phase['label']}: {MEANING_COMPUTATION} was called {counts[MEANING_COMPUTATION]} times, expected {phase['meaning']}")
        if counts[VALIDATION_ENTRY] != phase["validations"]:
            failures.append(f"{phase['label']}: {VALIDATION_ENTRY} was called {counts[VALIDATION_ENTRY]} times, expected {phase['validations']}")
    failures += [f"overall: {spec} was never called" for spec in specs if totals[spec] < 1]
    print("sv_prepared_once\t" + json.dumps(totals, sort_keys=True), flush=True)
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--operations", nargs="*", default=OPERATIONS, choices=OPERATIONS)
    parser.add_argument("--repeat", type=int, default=1)
    arguments = parser.parse_args()
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="java-cost-") as temporary:
        directory = Path(temporary)
        agent = build_agent(directory, fetch_asm(directory))
        classes = build_classes(directory, agent)
        print("operation\tjumps s(n)\tjumps s(10n)\tjumps ratio\tbytes s(n)\tbytes s(10n)\tbytes ratio")
        for name in arguments.operations:
            limit = LINEAR_RATIO_LIMIT if name in LINEAR_OPERATIONS else RATIO_LIMIT
            small = [measure(classes, agent, name, BASE_COUNT) for _ in range(arguments.repeat)]
            steps = small[0]["k"] * (GROWTH if small[0]["k"] == BASE_COUNT else 1)
            bounds = (
                int(limit * small[0]["jumps"] / small[0]["k"] * steps + 64),
                int(limit * small[0]["bytes"] / small[0]["k"] * steps + 4096),
            )
            large = [measure(classes, agent, name, BASE_COUNT * GROWTH, bounds) for _ in range(arguments.repeat)]
            if any(sample is None or sample.get("exceeded") for sample in large):
                print(f"{name}\t{small[0]['jumps'] / small[0]['k']:.3f}\t>{limit} * s({BASE_COUNT})", flush=True)
                failures.append(f"{name}: s({BASE_COUNT * GROWTH}) exceeds {limit} * s({BASE_COUNT})")
                continue
            row = [name]
            for quantity in ("jumps", "bytes"):
                s_small = small[0][quantity] / small[0]["k"]
                s_large = large[0][quantity] / large[0]["k"]
                ratio = s_large / s_small if s_small else (1.0 if s_large == 0 else float("inf"))
                row += [f"{s_small:.3f}", f"{s_large:.3f}", f"{ratio:.3f}"]
                if ratio > limit:
                    failures.append(f"{name}: {quantity} s({BASE_COUNT * GROWTH}) / s({BASE_COUNT}) = {ratio:.3f} exceeds {limit}")
            print("\t".join(row), flush=True)
            if name in EXACT_OPERATIONS and small[0]["jumps"] / small[0]["k"] != large[0]["jumps"] / large[0]["k"]:
                failures.append(f"{name}: jumps s({BASE_COUNT * GROWTH}) = {large[0]['jumps'] / large[0]['k']} differs from s({BASE_COUNT}) = {small[0]['jumps'] / small[0]['k']}")
            for group in (small, large):
                if any(sample["jumps"] != group[0]["jumps"] for sample in group):
                    failures.append(f"{name}: jump counts differ across {arguments.repeat} runs: {[s['jumps'] for s in group]}")
                spread = (max(s["bytes"] for s in group) - min(s["bytes"] for s in group)) / max(1, group[0]["bytes"])
                if spread > BYTES_SPREAD_LIMIT:
                    failures.append(f"{name}: allocated bytes spread {spread:.4f} across {arguments.repeat} runs")
        failures += check_prepared(classes, agent)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
