#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "verification" / "declaration"))
import signature_admission_exhaustive as exhaustive  # noqa: E402
GLEAM = os.environ.get("GLEAM", "gleam")

BUILD_CACHE = Path(os.environ.get("NCOH_GLEAM_BUILD_CACHE") or (Path(tempfile.gettempdir()) / "necoherence-gleam-build-cache"))


def absolutize_external_paths(original: Path, copy: Path) -> None:
    def resolved(match: re.Match[str]) -> str:
        target = (original / match.group(1)).resolve()
        return match.group(0) if target.is_relative_to(ROOT) else f'path = "{target}"'

    for name in ("gleam.toml", "manifest.toml"):
        text = (copy / name).read_text(encoding="utf-8")
        (copy / name).write_text(re.sub(r'path = "([^"]+)"', resolved, text), encoding="utf-8")


def link_build(project: Path) -> None:
    key = hashlib.sha256(str(project.resolve()).encode("utf-8")).hexdigest()
    target = BUILD_CACHE / key
    target.mkdir(parents=True, exist_ok=True)
    (project / "build").symlink_to(target, target_is_directory=True)


def command(argv: list[str], *, cwd: Path) -> str:
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout


def generator_executable() -> str:
    output = command(["cargo", "build", "--locked", "--quiet", "--manifest-path", str(ROOT / "generator/rust/Cargo.toml"),
                      "--bin", "necoherence-generate", "--message-format=json"], cwd=ROOT)
    for line in output.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("reason") == "compiler-artifact" and message.get("target", {}).get("name") == "necoherence-generate" \
                and message.get("executable"):
            return message["executable"]
    raise RuntimeError("necoherence-generate executable is not reported by cargo")


def snake(value: str) -> str:
    return "_".join(part.lower() for part in re.findall(r"[A-Za-z0-9]+", value))


def gleam_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def contract_type(contract: dict) -> str:
    return contract["type_id"]


def raw_value(module: str, context: str, type_id: str, value) -> tuple[list[str], str]:
    wire = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    name = f"value_{raw_value.counter}"
    raw_value.counter += 1
    return [f"  let assert Ok({name}) = {module}.decode_{snake(type_id)}({context}, {gleam_string(wire)})"], name


raw_value.counter = 0


def slot_value(module: str, context: str, contract: dict, description: dict) -> tuple[list[str], str]:
    tag = description["tag"]
    required, nullable = contract["required"], contract["nullable"]
    lines: list[str] = []
    raw = ""
    if tag == "present":
        lines, raw = raw_value(module, context, contract_type(contract), description.get("value"))
    if required and not nullable:
        return lines, raw
    if required and nullable:
        return lines, "None" if tag == "null" else f"Some({raw})"
    if not required and not nullable:
        return lines, "None" if tag == "absent" else f"Some({raw})"
    return lines, {"absent": "types.Absent", "null": "types.Null"}.get(tag, f"types.Present({raw})")


def attempt(description: dict) -> str:
    headers = ", ".join(
        f"network.RawHeaderField({gleam_string(item['name'])}, <<{', '.join(map(str, item['value']))}>>)"
        for item in description["headers"]
    )
    body = ", ".join(map(str, description["body"]))
    return (
        "network.AttemptInput(network.AttemptIdentity("
        f"progression.RequestIdentity(\"semantic\", {gleam_string(description.get('provenance', 'comparison'))}, 1), "
        f"{description.get('ordinal', 0)}), network.HttpWireInstruction({gleam_string(description['method'])}, "
        f"{gleam_string(description['target'])}, [{headers}], <<{body}>>), None, "
        "network.HostConfiguration(1024, 1024, None, None))"
    )


def provider_source(module: str, context: str, exchange: dict, index: int, description: dict) -> tuple[list[str], str]:
    signature = exchange["composition"]["problem"]["signatures"][index]

    def default_value(type_id: str):
        shape = next(node["shape"] for node in exchange["signatures"]["nodes"] if node["id"] == type_id)
        return {"Boolean": False, "String": "", "Unit": None}.get(shape["tag"], {})

    def outcome_source(value: dict, *, fallback: bool = False) -> tuple[list[str], str]:
        outcome_index = next((i for i, item in enumerate(signature["outcomes"]) if item["id"] == value.get("outcome")), 0 if fallback else None)
        if outcome_index is None:
            raise ValueError(f"unrepresentable outcome {value.get('outcome')}")
        outcome = signature["outcomes"][outcome_index]
        supplied = {item["id"]: item["value"] for item in value.get("outputs", [])}
        lines: list[str] = []
        fields: list[str] = []
        for port in outcome["value_ports"]:
            description = supplied.get(port["id"], {"tag": "present", "value": default_value(port["contract"]["type_id"])})
            created, rendered = slot_value(module, context, port["contract"], description)
            lines.extend(created)
            fields.append(rendered)
        return lines, f"{module}.Provider{index}Outcome{outcome_index}({', '.join(fields)})"

    if description["effect"] == "pure":
        lines, outcome = outcome_source(description)
        body = "\n".join(["fn(_) {", *lines, f"  Ok({outcome})", "}"])
        return [], body

    prepared = description["prepare"][0]
    if prepared["tag"] == "ready":
        prepare_lines = [f"  Ok({module}.Provider{index}HttpAttemptReady({attempt(prepared['request'])}))"]
    else:
        created, outcome = outcome_source(prepared, fallback=True)
        declared_index = next((i for i, item in enumerate(signature["outcomes"]) if item["id"] == prepared.get("outcome")), 0)
        prepare_lines = [*created, f"  Ok({module}.Provider{index}HttpAttemptCompleted(contract_{index}_{declared_index}, {outcome}))"]

    decode_arms: list[str] = []
    for decoded in description["decode"]:
        if "failure" in decoded:
            body = f"Error(runtime.ProviderFailure(composition.SiteId({gleam_string(decoded['failure'].get('site', 'operation'))}), {gleam_string(decoded['failure']['message'])}))"
            decode_arms.append(f"    {decoded['status']} -> {body}")
        else:
            created, outcome = outcome_source(decoded, fallback=True)
            decode_arms.extend([f"    {decoded['status']} -> {{", *["  " + line for line in created], f"      Ok({outcome})", "    }"])
    decode_arms.append('    _ -> Error(runtime.InvalidPlan("missing decode behavior"))')
    rendered = "\n".join([
        f"{module}.Provider{index}Http(",
        "fn(_) {", *prepare_lines, "},",
        "fn(response) {", "  let network.RawHttpResponse(status, _, _) = response", "  case status {", *decode_arms, "  }", "}", ")",
    ])
    return [], rendered


def observation_source(case: dict, value: dict) -> str:
    ready = [item for provider in case["providers"] for item in provider.get("prepare", []) if item["tag"] == "ready"]
    request = attempt(ready[value.get("request", 0)]["request"])
    prefix = f"{{ let network.AttemptInput(identity, _, _, configuration) = {request} "
    if value["tag"] == "start" and value.get("kind") == "started":
        return prefix + f"runtime.Start(network.StartedObservation(identity, network.ExecutionHandle({gleam_string(value.get('handle', 'handle'))}))) }}"
    if value["tag"] == "start":
        return prefix + "runtime.Start(network.StartFailed(network.NetworkHostFailure(identity, network.Start, configuration, network.ExecutionStartFailed), network.Unknown(network.NoResponse))) }"
    headers = ", ".join(
        f"network.RawHeaderField({gleam_string(item['name'])}, <<{', '.join(map(str, item['value']))}>>)" for item in value["headers"]
    )
    body = ", ".join(map(str, value["body"]))
    return prefix + (
        f"runtime.Host(network.Delivered({value.get('delivery', 0)}, network.ResponseObservation(identity, "
        f"network.ExecutionHandle({gleam_string(value.get('handle', 'handle'))}), network.NoSource, "
        f"network.RawHttpResponse({value['status']}, [{headers}], <<{body}>>), network.LibraryNormalized, "
        "network.Unknown(network.NoResponse)))) }"
    )


def slot_json(module: str, context: str, contract: dict, variable: str) -> str:
    encoder = f"{module}.encode_{snake(contract_type(contract))}({context}, value)"
    present = f'{{ let assert Ok(wire) = {encoder} "{{\\\"tag\\\":\\\"present\\\",\\\"value\\\":" <> wire <> "}}" }}'
    required, nullable = contract["required"], contract["nullable"]
    if required and not nullable:
        return f'{{ let assert Ok(wire) = {module}.encode_{snake(contract_type(contract))}({context}, {variable}) "{{\\\"tag\\\":\\\"present\\\",\\\"value\\\":" <> wire <> "}}" }}'
    if required and nullable:
        return f'case {variable} {{ None -> "{{\\\"tag\\\":\\\"null\\\"}}" Some(value) -> {present} }}'
    if not required and not nullable:
        return f'case {variable} {{ None -> "{{\\\"tag\\\":\\\"absent\\\"}}" Some(value) -> {present} }}'
    return f'case {variable} {{ types.Absent -> "{{\\\"tag\\\":\\\"absent\\\"}}" types.Null -> "{{\\\"tag\\\":\\\"null\\\"}}" types.Present(value) -> {present} }}'


def result_source(module: str, context: str, exchange: dict) -> list[str]:
    problem = exchange["composition"]["problem"]
    arms: list[str] = []
    outputs = problem["goal"]["outputs"]
    variables = [f"value_{i}" for i in range(len(outputs))]
    parts = []
    for variable, output in zip(variables, outputs):
        encoded = slot_json(module, context, output["contract"], variable)
        parts.append(f'"[" <> {gleam_string(json.dumps(output["id"]))} <> "," <> {encoded} <> "]"')
    outcome = ' <> "," <> '.join(parts) if parts else '""'
    arms.append(f"    {module}.Success({', '.join(variables)}) -> {{")
    arms.append(f"      let values = [{outcome}]")
    arms.append('      "{\\\"tag\\\":\\\"success\\\",\\\"outcome\\\":[" <> string.join(values, ",") <> "]}"')
    arms.append("    }")
    for index, failure in enumerate(problem["goal"]["failures"]):
        encoded = slot_json(module, context, failure["contract"], "value")
        prefix = json.dumps({"tag": "failure", "embedding": failure["id"]}, separators=(",", ":"))[:-1] + ',"value":'
        arms.extend([
            f"    {module}.Failure{index}(value) -> {{",
            f"      let encoded = {encoded}",
            f"      {gleam_string(prefix)} <> encoded <> \"}}\"",
            "    }",
        ])
    return arms


def case_source(number: int, case: dict) -> str:
    module = f"generated_{number}"
    context = "context"
    exchange = json.loads(case["exchange"])
    raw_value.counter = 0
    setup = [f"  let assert Ok({context}) = {module}.initialize()"]
    problem = exchange["composition"]["problem"]
    for index, signature in enumerate(problem["signatures"]):
        if case["providers"][index]["effect"] == "http" and case["providers"][index]["prepare"][0]["tag"] == "completed":
            contract_pattern = ", ".join(f"contract_{index}_{position}" for position in range(len(signature["outcomes"])))
            setup.extend([
                f"  let contracts_{index} = {module}.provider{index}_outcome_contracts(context)",
                f"  let assert [{contract_pattern}] = contracts_{index}",
            ])
    providers: list[str] = []
    for index, description in enumerate(case["providers"]):
        extra, rendered = provider_source(module, context, exchange, index, description)
        setup.extend(extra)
        providers.append(rendered)
    arguments: list[str] = []
    supplied = {item["id"]: item["value"] for item in case["arguments"]}
    for initial in problem["initial_inputs"]:
        if initial["source"]["tag"] != "Argument":
            continue
        lines, rendered = slot_value(module, context, initial["contract"], supplied[initial["id"]])
        setup.extend(lines)
        arguments.append(rendered)
    observations = ",\n    ".join(observation_source(case, value) for value in case["observations"])
    result_arms = result_source(module, context, exchange)
    identity = gleam_string(case["case"])
    prefix = json.dumps({"case": case["case"]}, separators=(",", ":"))[:-1] + ',"progress":['
    return "\n".join([
        f"fn run_case_{number}() -> String {{", *setup,
        f"  let providers = {module}.Providers" + (f"({', '.join(providers)})" if providers else ""),
        f"  let arguments = {module}.Arguments" + (f"({', '.join(arguments)})" if arguments else ""),
        f"  let observations = [{observations}]",
        f"  case {module}.run(context, providers, arguments, network.empty_state()) {{",
        f"    Error({module}.Execution(runtime.RunFailure(cause, _))) -> {gleam_string(prefix)} <> \"],\\\"failure\\\":\" <> failure_json(cause) <> \"}}\"",
        f"    Error({module}.CompositionAbsent) -> panic as \"generated composition is absent\"",
        "    Ok(started) -> {",
        f"      let #(progress, terminal) = drive_{number}(context, Ok(started), observations, [])",
        f"      let prefix = {gleam_string(prefix)} <> string.join(progress, \",\") <> \"]\"",
        "      case terminal {",
        '        Error(runtime.RunFailure(cause, _)) -> prefix <> ",\\\"failure\\\":" <> failure_json(cause) <> "}"',
        "        Ok(result) -> {", "          let encoded = case result {", *result_arms, "          }", '          prefix <> ",\\\"result\\\":" <> encoded <> "}"', "        }", "      }", "    }", "  }", "}",
        f"fn drive_{number}(context: {module}.Context, current: Result({module}.RunProgress, runtime.RunFailure), observations: List(runtime.ExecutionObservation), progress: List(String)) -> #(List(String), Result({module}.CompositionResult, runtime.RunFailure)) {{",
        "  case current {",
        "    Error(failure) -> #(list.reverse(progress), Error(failure))",
        f"    Ok({module}.Completed(result, _)) -> #(list.reverse([\"{{\\\"tag\\\":\\\"completed\\\"}}\", ..progress]), Ok(result))",
        f"    Ok({module}.Pending(execution, instruction)) -> {{",
        "      let assert [observation, ..rest] = observations",
        '      let item = case instruction { runtime.Send(_) -> "{\\\"tag\\\":\\\"pending\\\",\\\"instruction\\\":\\\"send\\\"}" runtime.Observe(_) -> "{\\\"tag\\\":\\\"pending\\\",\\\"instruction\\\":\\\"observe\\\"}" }',
        f"      drive_{number}(context, {module}.resume(context, execution, observation), rest, [item, ..progress])",
        "    }", "  }", "}",
    ])


LICENSE_LINE = "// SPDX-" + "License-Identifier:"
SUPPORT = '''// SPDX-License-Identifier: AGPL-3.0-only
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import necoherence/exact_json as exact
import necoherence/network_effect as network
import network_failure_json
import necoherence/composition_plan as composition
import necoherence/resource_witness
import necoherence/semantic_generation_decode as generation_decode
import necoherence/semantic_generation_runtime as runtime
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import necoherence/request_progression as progression
'''


FAILURES = (HERE / "generated_gleam_failures.gleam").read_text(encoding="utf-8")


def main() -> None:
    document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    scratch = Path(sys.argv[2]).resolve()
    shutil.rmtree(scratch, ignore_errors=True)
    execution_project = scratch / "verification/execution/gleam_driver"
    copies = [(ROOT / "packages/gleam/adapter", scratch / "packages/gleam/adapter"), (HERE / "gleam_driver", execution_project)]
    for original, copy in copies:
        shutil.copytree(original, copy, ignore=shutil.ignore_patterns("build"))
        absolutize_external_paths(original, copy)
    link_build(execution_project)
    shutil.copytree(HERE / "gleam_driver/build/packages", execution_project / "build/packages", dirs_exist_ok=True)
    generator = generator_executable()
    modules: dict[str, int] = {}
    render_failures: dict[str, str] = {}
    for case in document["cases"]:
        key = case["exchange"]
        if key in modules:
            continue
        number = len(modules)
        modules[key] = number
        exchange_path = scratch / f"exchange-{number}.json"
        expected_path = scratch / f"expected-{number}.json"
        output_path = scratch / f"generated-{number}.gleam"
        exchange_path.write_text(key, encoding="utf-8")
        exchange = json.loads(key)
        expected_path.write_text(json.dumps(exhaustive.expected_document(exchange["basis"], exchange["composition"])), encoding="utf-8")
        try:
            command([generator, "--target", "gleam", "--expected", str(expected_path), "--input", str(exchange_path),
                     "--output", str(output_path)], cwd=ROOT)
            source = output_path.read_text(encoding="utf-8")
            (execution_project / f"src/generated_{number}.gleam").write_text(source[source.index(LICENSE_LINE):], encoding="utf-8")
        except RuntimeError as failure:
            render_failures[key] = re.sub(r"\x1b\[[0-9;]*m", "", str(failure)).strip()
    cases = []
    for case in document["cases"]:
        original = modules[case["exchange"]]
        case = dict(case)
        cases.append((original, case))
    imports = [f"import generated_{number}" for key, number in modules.items() if key not in render_failures]
    bodies = []
    calls = []
    for index, (module_number, case) in enumerate(cases):
        if case["exchange"] in render_failures:
            calls.append(gleam_string(json.dumps({"case": case["case"], "progress": [], "driverFailure": render_failures[case["exchange"]]}, separators=(",", ":"))))
            continue
        if module_number != index:
            source = case_source(index, case).replace(f"generated_{index}", f"generated_{module_number}")
        else:
            source = case_source(index, case)
        bodies.append(source)
        calls.append(f"run_case_{index}()")
    runner = "\n".join([SUPPORT, *imports, FAILURES, *bodies, f"pub fn main() {{ io.println(\"[\" <> string.join([{', '.join(calls)}], \",\") <> \"]\") }}"])
    (execution_project / "src/generated_check.gleam").write_text(runner, encoding="utf-8")
    print(command([GLEAM, "run", "-m", "generated_check"], cwd=execution_project).strip())


if __name__ == "__main__":
    main()
