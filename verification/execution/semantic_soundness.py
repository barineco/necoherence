#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import argparse
import importlib.util
import itertools
import json
from pathlib import Path
import sys
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("execution_check", HERE / "check.py")
if spec is None or spec.loader is None:
    raise RuntimeError("execution comparison helpers unavailable")
check = importlib.util.module_from_spec(spec)
sys.modules["execution_check"] = check
spec.loader.exec_module(check)

SCENARIOS = ("pure", "http", "presence", "validate", "variant", "variant_projection", "flow", "field", "index")
CASE_LIMIT = 64
EFFECTS = {"DataOnly": "pure", "PureFunction": "pure", "HttpRequestResponse": "http"}
STARTED = {"tag": "start", "kind": "started", "handle": "handle"}
RESPONSE = {"tag": "host", "status": 200, "headers": [], "body": []}


class Types:
    def __init__(self, exchange: dict) -> None:
        library = exchange["signatures"]
        self.nodes = {node["id"]: node["shape"] for node in library["nodes"]}
        tag = library["profile"].get("tag") or {}
        self.tag_key = tag.get("key")
        self.sealed = {row["tag"]: row for row in tag.get("sealed", [])}

    def leaf_values(self, leaf: dict) -> list:
        if leaf["tag"] == "String":
            return self.string_values(leaf["value"])
        if leaf["tag"] == "Boolean":
            return [True, False]
        raise RuntimeError(f"unsupported sealed leaf {leaf['tag']}")

    @staticmethod
    def string_values(spec: dict) -> list:
        if spec.get("enum_values"):
            return list(spec["enum_values"])
        values = list(spec.get("examples") or []) or ["sample"]
        if not spec.get("lengths"):
            values.append("")
        return values

    def sealed_values(self, tag: str) -> list:
        row = self.sealed[tag]
        required = [field for field in row["fields"] if field["required"]]
        choices = [self.leaf_values(field["leaf"]) for field in required]
        return [{self.tag_key: tag, **{field["key"]: value for field, value in zip(required, chosen)}}
                for chosen in itertools.product(*choices)]

    def values(self, type_id: str) -> list:
        shape = self.nodes[type_id]
        kind = shape["tag"]
        if kind == "Boolean":
            return [True, False]
        if kind == "Unit":
            return [None]
        if kind == "String":
            return self.string_values(shape["value"])
        if kind == "Sealed":
            return self.sealed_values(shape["fields"]["tag"])
        if kind == "TaggedUnion":
            return [value for branch in shape["value"]["branches"] for value in self.values(branch["target"])]
        if kind == "Product":
            fields = shape["value"]["fields"]
            choices = [self.values(field["slot"]["type_id"]) for field in fields]
            rows = [dict(zip((field["wire_name"] for field in fields), chosen)) for chosen in itertools.product(*choices)]
            return rows[:8]
        if kind == "Array":
            array = shape["value"]
            items = self.values(array["item"]["type_id"])
            lengths = {int(array.get("min_length") or 0), int(array.get("max_length") or array.get("min_length") or 1)}
            return [[items[index % len(items)] for index in range(length)] for length in sorted(lengths)] + \
                   [[items[(index + 1) % len(items)] for index in range(length)] for length in sorted(lengths) if length]
        raise RuntimeError(f"unsupported shape {kind}")

    def wrong(self, type_id: str):
        return 0 if self.nodes[type_id]["tag"] != "Unit" else "not-unit"

    def conforms(self, type_id: str, value) -> bool:
        shape = self.nodes[type_id]
        kind = shape["tag"]
        if kind == "Boolean":
            return isinstance(value, bool)
        if kind == "Unit":
            return value is None
        if kind == "String":
            return isinstance(value, str)
        if kind == "Sealed":
            tag = shape["fields"]["tag"]
            row = self.sealed[tag]
            keys = {self.tag_key, *(field["key"] for field in row["fields"])}
            return (isinstance(value, dict) and value.get(self.tag_key) == tag and set(value) <= keys
                    and all(field["key"] in value for field in row["fields"] if field["required"]))
        if kind == "TaggedUnion":
            return any(self.conforms(branch["target"], value) for branch in shape["value"]["branches"])
        if kind == "Product":
            fields = shape["value"]["fields"]
            return (isinstance(value, dict) and set(value) <= {field["wire_name"] for field in fields}
                    and all(self.slot_conforms(field["slot"], value.get(field["wire_name"], ABSENT)) for field in fields))
        if kind == "Array":
            array = shape["value"]
            minimum = int(array.get("min_length") or 0)
            maximum = int(array["max_length"]) if array.get("max_length") is not None else None
            return (isinstance(value, list) and len(value) >= minimum and (maximum is None or len(value) <= maximum)
                    and all(self.slot_conforms({**array["item"], "required": True}, item) for item in value))
        raise RuntimeError(f"unsupported shape {kind}")

    def slot_conforms(self, slot: dict, value) -> bool:
        if value is ABSENT:
            return not slot.get("required", True)
        if value is None and self.nodes[slot["type_id"]]["tag"] != "Unit":
            return bool(slot.get("nullable"))
        return self.conforms(slot["type_id"], value)

    def contract_conforms(self, contract: dict, observed: dict) -> bool:
        if observed["tag"] == "absent":
            return not contract["required"]
        if observed["tag"] == "null":
            return contract["nullable"]
        return self.conforms(contract["type_id"], observed["value"])


ABSENT = object()


def argument_choices(types: Types, contract: dict) -> list[tuple[dict, bool]]:
    choices = [({"tag": "present", "value": value}, True) for value in types.values(contract["type_id"])]
    if not contract["required"]:
        choices.append(({"tag": "absent"}, True))
    if contract["nullable"]:
        choices.append(({"tag": "null"}, True))
    choices.append(({"tag": "present", "value": types.wrong(contract["type_id"])}, False))
    return choices


def provider_choices(types: Types, index: int, signature: dict) -> list[tuple[dict, bool]]:
    effect = EFFECTS[signature["effect"]["tag"]]
    choices = []
    for outcome in signature["outcomes"]:
        outputs = [{"id": port["id"], "value": {"tag": "present", "value": types.values(port["contract"]["type_id"])[0]}}
                   for port in outcome["value_ports"]]
        choices.append((check.provider(effect, outcome["id"], outputs, signature=index), True))
    choices.append((check.provider(effect, "undeclared", [], signature=index), False))
    return choices


def scenario_cases(name: str, text: str) -> list[dict]:
    exchange = json.loads(text)
    problem = exchange["composition"]["problem"]
    types = Types(exchange)
    arguments = [item for item in problem["initial_inputs"] if item["source"]["tag"] == "Argument"]
    argument_axes = [[(item["id"], value, typed) for value, typed in argument_choices(types, item["contract"])] for item in arguments]
    provider_axes = [provider_choices(types, index, signature) for index, signature in enumerate(problem["signatures"])]
    http = any(EFFECTS[signature["effect"]["tag"]] == "http" for signature in problem["signatures"])
    rows = []
    for number, chosen in enumerate(itertools.product(*argument_axes, *provider_axes)):
        if number >= CASE_LIMIT:
            break
        chosen_arguments = chosen[:len(argument_axes)]
        chosen_providers = chosen[len(argument_axes):]
        rows.append({
            "case": f"{name}/{number}",
            "exchange": text,
            "arguments": [{"id": identity, "value": value} for identity, value, _ in chosen_arguments],
            "providers": [value for value, _ in chosen_providers],
            "observations": [STARTED, RESPONSE] if http else [],
            "generated": all(typed for _, _, typed in chosen_arguments) and all(typed for _, typed in chosen_providers),
            "expected": check.canonical(check.exhaustive.expected_document(exchange["basis"], exchange["composition"])),
        })
    return rows


def in_range(types: Types, goal: dict, observations: dict, row: dict, language: str) -> list[str]:
    problems = []
    for step in row.get("progress", []):
        if step["tag"] == "pending":
            if "network_instruction" not in observations["effects"] or "pending" not in observations["effects"]:
                problems.append(f"undeclared pending step {step}")
        elif step["tag"] != "completed":
            problems.append(f"unknown progress step {step}")
    if "failure" in row:
        tag = check.normalized(language, row)["failure"]["tag"]
        if tag not in observations["execution_failures"]:
            problems.append(f"undeclared execution failure {tag}")
        return problems
    result = row.get("result")
    if result is None:
        if not row.get("progress") or row["progress"][-1]["tag"] != "pending":
            problems.append("neither a result, a failure nor a pending step")
        return problems
    if result["tag"] == "success":
        outputs = {output["id"]: output for output in goal["outputs"]}
        ports = dict(result["outcome"])
        if set(ports) != set(outputs):
            problems.append(f"success ports {sorted(ports)} differ from the declared {sorted(outputs)}")
        for port, value in ports.items():
            if port in outputs and not types.contract_conforms(outputs[port]["contract"], value):
                problems.append(f"port {port} value {value} is outside {outputs[port]['contract']}")
    elif result["tag"] == "failure":
        failures = {failure["id"]: failure for failure in goal["failures"]}
        embedding = result["embedding"]
        if embedding not in failures:
            problems.append(f"undeclared failure embedding {embedding}")
        elif not types.contract_conforms(failures[embedding]["contract"], result["value"]):
            problems.append(f"embedding {embedding} value {result['value']} is outside {failures[embedding]['contract']}")
    else:
        problems.append(f"unknown result tag {result['tag']}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("languages", nargs="*", default=["lean", "rust", "python", "typescript", "java", "gleam"])
    parser.add_argument("--phase", choices=("kernel", "generated", "both"), default="both")
    parser.add_argument("--lean-results", type=Path,
                        help="a file that keeps the Lean rows of one phase, written when absent and read when present")
    options = parser.parse_args()
    selected = list(options.languages)
    if "lean" not in selected:
        selected.insert(0, "lean")
    output = check.command([check.cargo(), "run", "--locked", "--quiet", "--manifest-path", str(HERE / "rust_driver/Cargo.toml"),
                            "--bin", "generate"], input_text=check.canonical({"scenarios": list(SCENARIOS)}))
    texts = json.loads(output)
    rows = [row for name in SCENARIOS for row in scenario_cases(name, texts[name])]
    contexts = {}
    for name in SCENARIOS:
        exchange = json.loads(texts[name])
        contexts[name] = (Types(exchange), exchange["composition"]["problem"]["goal"],
                          check.exhaustive.goal_observations(exchange["composition"]))
    failures = []
    with tempfile.TemporaryDirectory(prefix="ncoh-semantic-soundness-") as directory:
        scratch = Path(directory)
        kernel_path, generated_path = scratch / "cases.json", scratch / "generated-cases.json"
        kernel_path.write_text(check.canonical({"schema": "ncoh-execution-comparison@1", "cases": rows}), encoding="utf-8")
        generated_path.write_text(check.canonical({"schema": "ncoh-execution-comparison@1",
                                                    "cases": [row for row in rows if row["generated"]]}), encoding="utf-8")
        java_build = scratch / "java"
        java_build.mkdir()
        if "java" in selected:
            library = check.os.environ.get("NCOH_JAVA_EXECUTION_CLASSPATH", str(check.ROOT / "packages/java/adapter/build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar"))
            quotient_sources = sorted(str(source) for root in (check.NECO_QUOTIENT_JAVA, check.NECO_QUOTIENT_APPLICATION_JAVA, check.NECO_QUOTIENT_RETENTION_JAVA, check.NECO_QUOTIENT_ENCODING_JAVA) for source in Path(root).rglob("*.java"))
            check.command(["javac", "--release", "21", "-cp", library, *check.java_sourcepath(), "-d", str(java_build),
                           str(HERE / "java_driver/NetworkFailureJson.java"), str(HERE / "java_driver/ValueFailureJson.java"),
                           str(HERE / "java_driver/ExecutionCheck.java"), *quotient_sources])
        phases = {"kernel": (check.runners(kernel_path, java_build), check.normalized),
                  "generated": (check.generated_runners(generated_path, scratch / "generated"), lambda language, row: row)}
        if options.phase != "both":
            phases = {options.phase: phases[options.phase]}
        reached = {name: set() for name in SCENARIOS}
        counts = {}
        for phase, (specs, normal) in phases.items():
            lean_file = options.lean_results.with_suffix(f".{phase}.json") if options.lean_results else None
            outputs = {}
            for language, (argv, cwd) in specs.items():
                if language not in selected:
                    continue
                if language == "lean" and lean_file is not None and lean_file.exists():
                    text = lean_file.read_text(encoding="utf-8")
                else:
                    text = check.command(argv, cwd=cwd)
                    if language == "lean" and lean_file is not None:
                        lean_file.write_text(text, encoding="utf-8")
                outputs[language] = {row["case"]: row for row in json.loads(text)}
            counts[phase] = len(outputs["lean"])
            for identity, lean_row in outputs["lean"].items():
                name = identity.split("/")[0]
                types, goal, observations = contexts[name]
                result = lean_row.get("result")
                if result is not None:
                    reached[name].add(result.get("embedding", "success"))
                for language, table in outputs.items():
                    row = table[identity]
                    failures.extend(f"{phase} {identity} {language}: {problem}" for problem in in_range(types, goal, observations, row, language))
                    if language != "lean" and normal(language, row) != normal("lean", lean_row):
                        failures.append(f"{phase} {identity}: {language} differs from Lean")
        for name in SCENARIOS:
            _, goal, _ = contexts[name]
            declared = {"success"} | {failure["id"] for failure in goal["failures"]}
            missing = declared - reached[name]
            if missing:
                failures.append(f"{name}: the generated inputs reach no result for {sorted(missing)}")
        print(json.dumps({"cases": counts, "languages": selected,
                          "reached": {name: sorted(values) for name, values in reached.items()}}, sort_keys=True))
    for failure in failures:
        print(failure, file=sys.stderr)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
