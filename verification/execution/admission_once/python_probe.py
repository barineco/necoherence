#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tracemalloc

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / "packages/python/adapter/src")]

import neco_quotient_application.application as quotient_application
import neco_quotient_certificate.admission as quotient_admission
import necoherence.network_effect as ne
import necoherence.signature_composition_wire as composition_wire
import necoherence.type_signatures as type_signatures

COMPONENTS = {
    "decode": [type_signatures.decode_generation],
    "sha256": [type_signatures._sha],
    "checkLibrary": [type_signatures.checkLibrary],
    "graph": [type_signatures._graph, composition_wire._graph],
    "preparation": [composition_wire._admit_composition, composition_wire.prepare_composition_input],
    "admit": [quotient_admission.admit],
    "blocks": [quotient_application.keyed_blocks_of],
}

INITIALIZATION = {
    "basis": type_signatures.signature_basis,
    "composition": composition_wire._admit_composition,
    "sha256": type_signatures._sha,
}


def load(path: Path):
    spec = importlib.util.spec_from_file_location("generated_admission_once", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("generated module unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run_once(module, generation):
    providers = module.Providers(call0=lambda arguments: module.Outcome0K0(output=arguments.input))
    result = module.run(generation, providers, module.Arguments(argument=True), ne.empty_network_state())
    if not isinstance(result, module.RunCompleted):
        raise RuntimeError(f"run did not complete: {result!r}")
    return result


def main() -> None:
    module = load(Path(sys.argv[1]))
    runs = int(sys.argv[2])
    monitoring = sys.monitoring
    tool = 4
    initialization_owners = {function.__code__: name for name, function in INITIALIZATION.items()}
    initialization_calls = {name: 0 for name in INITIALIZATION}

    def initialization_started(code, offset):
        name = initialization_owners.get(code)
        if name is not None:
            initialization_calls[name] += 1
        return None

    monitoring.use_tool_id(tool, "admission-once-initialization")
    monitoring.register_callback(tool, monitoring.events.PY_START, initialization_started)
    monitoring.set_events(tool, monitoring.events.PY_START)
    generation = module.initialize()
    monitoring.set_events(tool, 0)
    monitoring.register_callback(tool, monitoring.events.PY_START, None)
    monitoring.free_tool_id(tool)
    if isinstance(generation, (module.InitializePreparation, module.InitializeAdmission)):
        raise RuntimeError(f"initialization failed: {generation!r}")
    run_once(module, generation)

    monitoring.use_tool_id(tool, "admission-once")
    owners = {function.__code__: name for name, functions in COMPONENTS.items() for function in functions}
    calls = {name: 0 for name in COMPONENTS}
    instructions = [0]

    def started(code, offset):
        name = owners.get(code)
        if name is not None:
            calls[name] += 1
        return None

    def instruction(code, offset):
        instructions[0] += 1
        return None

    monitoring.register_callback(tool, monitoring.events.PY_START, started)
    monitoring.register_callback(tool, monitoring.events.INSTRUCTION, instruction)
    monitoring.set_events(tool, monitoring.events.PY_START | monitoring.events.INSTRUCTION)
    for _ in range(runs):
        run_once(module, generation)
    monitoring.set_events(tool, 0)
    monitoring.free_tool_id(tool)

    tracemalloc.start()
    peak = 0
    for _ in range(runs):
        tracemalloc.reset_peak()
        before, _ = tracemalloc.get_traced_memory()
        run_once(module, generation)
        _, highest = tracemalloc.get_traced_memory()
        peak += highest - before
    tracemalloc.stop()
    print(json.dumps({"calls": calls, "init": initialization_calls, "quantity": instructions[0] / runs, "second": peak / runs}))


if __name__ == "__main__":
    main()
