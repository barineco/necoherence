#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "verification" / "declaration"))
import signature_admission_exhaustive as exhaustive  # noqa: E402
EXECUTION = HERE.parent
GENERATOR_MANIFEST = ROOT / "generator/rust/Cargo.toml"
EXCHANGE_MANIFEST = EXECUTION / "rust_driver/Cargo.toml"
SMALL_PADDING = 0
LARGE_PADDING = 4000
RUNS = 20
COMPONENTS = ("decode", "sha256", "checkLibrary", "graph", "preparation", "admit", "blocks")
EQUAL_QUANTITY = {"python", "typescript", "java"}
RUST_PADDINGS = {"n": SMALL_PADDING, "2n": 436, "5n": 1730, "10n": LARGE_PADDING}
RUST_LIMIT = 1.1204037
SECOND_QUANTITY = {"python", "typescript", "java"}
SECOND_RATIO = 2.0
TYPE_PADDING = 4000
TYPE_GROWTH = {"python", "typescript"}
JAVA_TYPE_PADDINGS = (150, 1500)
INITIALIZATION_ONCE = {
    "python": {"basis": "type_signatures.signature_basis", "composition": "signature_composition_wire._admit_composition"},
    "rust": {"basis": "signature_admission::signature_basis", "composition": "decode_signature_composition_wire"},
    "typescript": {"basis": "signatureBasis", "composition": "admitSignatureComposition"},
    "gleam": {"basis": "semantic_signatures:calculate_generation_identity/3", "composition": "semantic_signatures:decode_generation_composition/2"},
    "java": {"basis": "TypeSignatures.computeBasis", "composition": "TypeSignatures.admitComposition"},
}


def command(argv: list[str], *, cwd: Path = ROOT, input_text: str | None = None, env: dict[str, str] | None = None) -> str:
    completed = subprocess.run(argv, cwd=cwd, input=input_text, text=True, capture_output=True, env=env)
    if completed.returncode != 0:
        raise RuntimeError(f"{' '.join(argv)}\n{completed.stdout}\n{completed.stderr}")
    return completed.stdout


def scenarios(names: list[str]) -> dict[str, str]:
    output = command(["cargo", "run", "--locked", "--quiet", "--manifest-path", str(EXCHANGE_MANIFEST), "--bin", "generate"],
                     input_text=json.dumps({"scenarios": names}))
    return json.loads(output)


def exchanges(paddings=(SMALL_PADDING, LARGE_PADDING)) -> dict[int, str]:
    values = scenarios([f"pure_padded_{padding}" for padding in paddings])
    return {padding: values[f"pure_padded_{padding}"] for padding in paddings}


def render(target: list[str], exchange: str, output: Path) -> None:
    expected = output.with_suffix(".expected.json")
    document = output.with_suffix(".input.json")
    value = json.loads(exchange)
    expected.write_text(json.dumps(exhaustive.expected_document(value["basis"], value["composition"])), encoding="utf-8")
    document.write_text(exchange, encoding="utf-8")
    command(["cargo", "run", "--quiet", "--locked", "--manifest-path", str(GENERATOR_MANIFEST), "--bin", "necoherence-generate", "--",
             *target, "--expected", str(expected), "--input", str(document), "--output", str(output)])


def python_probe(exchange: str, scratch: Path) -> dict:
    module = scratch / "generated.py"
    render(["--target", "python"], exchange, module)
    return json.loads(command([sys.executable, str(HERE / "python_probe.py"), str(module), str(RUNS)]))


def typescript_probe(exchange: str, scratch: Path) -> dict:
    module = scratch / "generated.mts"
    runtime = (ROOT / "packages/typescript/adapter/src/index.ts").as_uri()
    render(["--target", "typescript", "--runtime", runtime], exchange, module)
    return json.loads(command(["node", "--no-opt", "--no-sparkplug", "--no-maglev", "--import", "tsx",
                               str(HERE / "typescript_probe.ts"), str(module), str(RUNS)], cwd=ROOT / "packages/typescript/adapter"))


def gleam_probe(exchange: str, scratch: Path) -> dict:
    sys.path.insert(0, str(EXECUTION))
    import generated_gleam_driver as gleam_cases

    project_root = EXECUTION / "generated-packages/admission-once-gleam"
    shutil.rmtree(project_root, ignore_errors=True)
    project = project_root / "verification/execution/gleam_driver"
    for original, copy in ((ROOT / "packages/gleam/adapter", project_root / "packages/gleam/adapter"), (EXECUTION / "gleam_driver", project)):
        shutil.copytree(original, copy, ignore=shutil.ignore_patterns("build"))
        gleam_cases.absolutize_external_paths(original, copy)
    gleam_cases.link_build(project)
    shutil.copytree(EXECUTION / "gleam_driver/build/packages", project / "build/packages", dirs_exist_ok=True)
    try:
        generated = scratch / "generated.gleam"
        render(["--target", "gleam"], exchange, generated)
        source = generated.read_text(encoding="utf-8")
        (project / "src/generated_probe.gleam").write_text(source[source.index(gleam_cases.LICENSE_LINE):], encoding="utf-8")
        exchange_value = json.loads(exchange)
        description = {"reference": "declared", "effect": "pure", "signature": 0, "outcome": "success",
                       "outputs": [{"id": "output", "value": {"tag": "present", "value": True}}]}
        gleam_cases.raw_value.counter = 0
        setup, provider = gleam_cases.provider_source("generated_probe", "context", exchange_value, 0, description)
        initial = next(item for item in exchange_value["composition"]["problem"]["initial_inputs"] if item["source"]["tag"] == "Argument")
        lines, argument = gleam_cases.slot_value("generated_probe", "context", initial["contract"], {"tag": "present", "value": True})
        support = "\n".join([
            gleam_cases.SUPPORT, "import generated_probe",
            "pub fn setup() -> fn() -> Nil {",
            "  let assert Ok(context) = generated_probe.initialize()", *setup, *lines,
            f"  let providers = generated_probe.Providers({provider})",
            f"  let arguments = generated_probe.Arguments({argument})",
            "  fn() { let assert Ok(generated_probe.Completed(_, _)) = generated_probe.run(context, providers, arguments, network.empty_state()) Nil }",
            "}",
        ])
        (project / "src/probe_support.gleam").write_text(support, encoding="utf-8")
        shutil.copy(HERE / "admission_probe.erl", project / "src/admission_probe.erl")
        command([os.environ.get("GLEAM", "gleam"), "build"], cwd=project)
        paths = [str(path) for path in (project / "build/dev/erlang").glob("*/ebin")]
        output = command(["erl", "-noshell", *[argument for path in paths for argument in ("-pa", path)], "-run", "admission_probe", "main", str(RUNS)], cwd=project)
        return json.loads(output.strip().splitlines()[-1])
    finally:
        shutil.rmtree(project_root, ignore_errors=True)


RUST_PROBE = """
struct Host;
impl composed::Providers for Host {
    fn call_0(&mut self, _: composed::Function0Input) -> std::result::Result<composed::Function0Outcome, necoherence::semantic_execution::ExecutionFailure> {
        Ok(composed::Function0Outcome::Outcome0(composed::Function0Outcome0 { output: truth(true) }))
    }
}
#[no_mangle]
pub extern "C" fn probe(runs: u32) -> u32 {
    let generation = initialize().unwrap();
    let prepared = composed::prepare(&generation).unwrap();
    for _ in 0..runs {
        match composed::run(&prepared, Host, composed::Arguments { argument: truth(true) }, Default::default()) {
            Ok(composed::RunProgress::Completed(..)) => {}
            _ => panic!("run did not complete"),
        }
    }
    runs
}
"""


def wasm_succeeds(wasm: Path, fuel: int, runs: int) -> bool:
    completed = subprocess.run(["wasmtime", "run", "-W", f"fuel={fuel}", "--invoke", "probe", str(wasm), str(runs)],
                               text=True, capture_output=True)
    if completed.returncode == 0:
        return True
    if "fuel" in completed.stderr:
        return False
    raise RuntimeError(completed.stderr)


def least_fuel(wasm: Path, runs: int, lower: int) -> int:
    upper = max(2 * lower, 1 << 20)
    while not wasm_succeeds(wasm, upper, runs):
        lower, upper = upper, 2 * upper
    while upper - lower > 1:
        middle = (lower + upper) // 2
        if wasm_succeeds(wasm, middle, runs):
            upper = middle
        else:
            lower = middle
    return upper


def rust_wasm(exchange: str, scratch: Path) -> Path:
    project = EXECUTION / "generated-packages/admission-once-rust"
    shutil.rmtree(project, ignore_errors=True)
    (project / "src").mkdir(parents=True)
    try:
        generated = scratch / "generated.rs"
        render(["--target", "rust"], exchange, generated)
        (project / "src/lib.rs").write_text(generated.read_text(encoding="utf-8") + RUST_PROBE, encoding="utf-8")
        (project / "Cargo.toml").write_text(
            '[package]\nname="admission-once-probe"\nversion="0.0.0"\nedition="2021"\n\n[workspace]\n\n[lib]\ncrate-type=["cdylib"]\n\n'
            f'[dependencies]\nnecoherence={{path={json.dumps(str(ROOT / "packages/rust/adapter"))}}}\n'
            'serde_json={version="1",features=["arbitrary_precision"]}\n\n[profile.release]\npanic="abort"\n', encoding="utf-8")
        output = command(["cargo", "build", "--quiet", "--release", "--target", "wasm32-unknown-unknown", "--message-format=json",
                          "--manifest-path", str(project / "Cargo.toml")], cwd=project)
        built = next(Path(name) for line in output.splitlines() if line.startswith("{")
                     for message in [json.loads(line)] if message.get("reason") == "compiler-artifact"
                     and message.get("target", {}).get("name") == "admission_once_probe"
                     for name in message.get("filenames", []) if name.endswith(".wasm"))
        wasm = scratch / "probe.wasm"
        shutil.copy(built, wasm)
        return wasm
    finally:
        shutil.rmtree(project, ignore_errors=True)


RUST_COVERAGE_MAIN = """
fn main() {
    let runs: u32 = std::env::args().nth(1).and_then(|text| text.parse().ok()).unwrap_or(0);
    probe(runs);
}
"""
RUST_COMPONENTS = {
    "decode": ("decode_signature_generation", "decode_expected_signature_basis"),
    "sha256": ("sha2",),
    "checkLibrary": ("check_type_signatures",),
    "graph": ("generation_components",),
    "preparation": ("prepare_signature_composition", "decode_signature_composition_wire"),
    "admit": ("neco_quotient_certificate", "admit"),
    "blocks": ("neco_quotient_application", "keyed_blocks_of"),
}


RUST_INITIALIZATION = {
    "basis": (r"(?<![0-9])15signature_basis(?![a-z_0-9])",),
    "composition": (r"(?<![0-9])33decode_signature_composition_wire(?![a-z_0-9])",),
    "sha256": (r"(?<![0-9])19signature_admission4hash(?![a-z_0-9])", r"(?<![0-9])11utf8_sha256(?![a-z_0-9])"),
}


def llvm_tool(name: str) -> str:
    directory = os.environ.get("NCOH_LLVM_BIN")
    if directory:
        return str(Path(directory) / name)
    sysroot = command(["rustc", "--print", "sysroot"]).strip()
    host = next(line.split(": ")[1] for line in command(["rustc", "-vV"]).splitlines() if line.startswith("host: "))
    return str(Path(sysroot) / "lib/rustlib" / host / "bin" / name)


def rust_component(name: str) -> str | None:
    for component, keys in RUST_COMPONENTS.items():
        if component in ("admit", "blocks"):
            if keys[0] in name and f"{len(keys[1])}{keys[1]}" in name:
                return component
        elif any(f"{len(key)}{key}" in name for key in keys):
            return component
    return None


def rust_coverage(exchange: str, scratch: Path) -> dict:
    project = EXECUTION / "generated-packages/admission-once-rust-coverage"
    shutil.rmtree(project, ignore_errors=True)
    (project / "src").mkdir(parents=True)
    try:
        generated = scratch / "generated.rs"
        render(["--target", "rust"], exchange, generated)
        (project / "src/main.rs").write_text(generated.read_text(encoding="utf-8").replace("#[no_mangle]\n", "") + RUST_PROBE.replace("#[no_mangle]\npub extern \"C\" fn", "fn") + RUST_COVERAGE_MAIN, encoding="utf-8")
        (project / "Cargo.toml").write_text(
            '[package]\nname="admission-once-coverage"\nversion="0.0.0"\nedition="2021"\n\n[workspace]\n\n'
            f'[dependencies]\nnecoherence={{path={json.dumps(str(ROOT / "packages/rust/adapter"))}}}\n'
            'serde_json={version="1",features=["arbitrary_precision"]}\n', encoding="utf-8")
        target = scratch / "target"
        environment = {**os.environ, "RUSTFLAGS": "-C instrument-coverage", "CARGO_TARGET_DIR": str(target)}
        output = command(["cargo", "build", "--quiet", "--release", "--message-format=json", "--manifest-path", str(project / "Cargo.toml")],
                         cwd=project, env=environment)
        binary = next(Path(message["executable"]) for line in output.splitlines() if line.startswith("{")
                      for message in [json.loads(line)] if message.get("reason") == "compiler-artifact" and message.get("executable"))
        counts = {}
        for runs in (0, RUNS):
            raw = scratch / f"runs-{runs}.profraw"
            command([str(binary), str(runs)], env={**os.environ, "LLVM_PROFILE_FILE": str(raw)})
            merged = scratch / f"runs-{runs}.profdata"
            command([llvm_tool("llvm-profdata"), "merge", "-sparse", str(raw), "-o", str(merged)])
            exported = json.loads(command([llvm_tool("llvm-cov"), "export", "--format=text", "--skip-expansions",
                                           f"--instr-profile={merged}", str(binary)]))
            counts[runs] = {function["name"]: function["count"] for function in exported["data"][0]["functions"]}
        calls = dict.fromkeys(COMPONENTS, 0)
        for name, count in counts[RUNS].items():
            component = rust_component(name)
            if component is not None:
                calls[component] += count - counts[0].get(name, 0)
        init = dict.fromkeys(RUST_INITIALIZATION, 0)
        for name, count in counts[0].items():
            for component, patterns in RUST_INITIALIZATION.items():
                if any(re.search(pattern, name) for pattern in patterns):
                    init[component] += count
        return calls, init
    finally:
        shutil.rmtree(project, ignore_errors=True)


def rust_amortized(wasm: Path) -> dict:
    initialized = least_fuel(wasm, 0, 0)
    repeated = least_fuel(wasm, RUNS, initialized)
    return {"calls": None, "quantity": (repeated - initialized) / RUNS, "second": None, "initialized": initialized}


def rust_bounded(wasm: Path, limit: float) -> dict:
    initialized = least_fuel(wasm, 0, 0)
    budget = initialized + int(limit * RUNS)
    if not wasm_succeeds(wasm, budget, RUNS):
        return {"calls": None, "quantity": None, "second": None, "initialized": initialized, "budget": budget}
    repeated = least_fuel(wasm, RUNS, initialized)
    return {"calls": None, "quantity": (repeated - initialized) / RUNS, "second": None, "initialized": initialized, "budget": budget}


def rust_probe(exchange: str, scratch: Path) -> dict:
    observed = rust_amortized(rust_wasm(exchange, scratch))
    observed["calls"], observed["init"] = rust_coverage(exchange, scratch)
    return observed


def java_probe(exchange: str, scratch: Path) -> dict:
    library = Path(os.environ.get("NCOH_JAVA_EXECUTION_CLASSPATH",
                                  ROOT / "packages/java/adapter/build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar"))
    asm = Path(os.environ["NCOH_ASM_JAR"])
    agent_classes, probe_classes = scratch / "agent", scratch / "probe"
    agent_classes.mkdir()
    probe_classes.mkdir()
    command(["javac", "--release", "21", "-cp", str(asm), "-d", str(agent_classes),
             *[str(path) for path in (HERE / "java").glob("Admission[AC]*.java")]])
    command(["jar", "--extract", "--file", str(asm)], cwd=agent_classes)
    shutil.rmtree(agent_classes / "META-INF", ignore_errors=True)
    manifest = scratch / "manifest.txt"
    manifest.write_text("Premain-Class: admissiononce.AdmissionAgent\n", encoding="utf-8")
    agent = scratch / "agent.jar"
    command(["jar", "--create", "--file", str(agent), "--manifest", str(manifest), "-C", str(agent_classes), "."])
    generated = scratch / "GeneratedProbe.java"
    render(["--target", "java", "--java-package", "", "--java-class", "GeneratedProbe"], exchange, generated)
    classpath = os.pathsep.join((str(agent_classes), str(library)))
    quotient_sources = sorted(str(source) for root in (os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"]) for source in Path(root).rglob("*.java"))
    command(["javac", "--release", "21", "-cp", classpath, "-d", str(probe_classes), str(generated), str(HERE / "java/AdmissionProbe.java"), *quotient_sources])
    run_path = os.pathsep.join((str(probe_classes), str(library)))
    counted = json.loads(command(["java", f"-javaagent:{agent}", "-cp", run_path, "AdmissionProbe", str(RUNS), "count"]).strip())
    allocated = json.loads(command(["java", "-Xint", "-cp", run_path, "AdmissionProbe", str(RUNS), "allocation"]).strip())
    return {**counted, **allocated}


PROBES = {
    "python": python_probe,
    "java": java_probe,
    "rust": rust_probe,
    "typescript": typescript_probe,
    "gleam": gleam_probe,
}


def assess(language: str, small: dict, large: dict, gleam_threshold: float | None) -> list[str]:
    failures = []
    for label, observed in (("n", small), ("10n", large)):
        for component, function in INITIALIZATION_ONCE[language].items():
            count = (observed.get("init") or {}).get(component)
            if count != 1:
                failures.append(f"{language} {label}: {function} called {count} times in one initialization, expected exactly 1")
        if observed["calls"] is None:
            continue
        for component in COMPONENTS:
            if observed["calls"].get(component) != 0:
                failures.append(f"{language} {label}: {component} called {observed['calls'].get(component)} times after initialization")
    if language in EQUAL_QUANTITY and large["quantity"] != small["quantity"]:
        failures.append(f"{language}: quantity differs between n ({small['quantity']}) and 10n ({large['quantity']})")
    if language in SECOND_QUANTITY and large["second"] > SECOND_RATIO * small["second"]:
        failures.append(f"{language}: second quantity ratio {large['second'] / small['second']} exceeds {SECOND_RATIO}")
    if language == "rust" and large["quantity"] is None:
        failures.append(f"rust: the 10n runs exceed {RUST_LIMIT} times the fuel per run at n ({small['quantity']})")
    if language == "gleam":
        if gleam_threshold is None:
            failures.append("gleam: the reductions threshold is required")
        elif large["quantity"] > gleam_threshold * small["quantity"]:
            failures.append(f"gleam: reductions ratio {large['quantity'] / small['quantity']} exceeds {gleam_threshold}")
    return failures


def rust_sizes(repeat: int) -> int:
    documents = exchanges(tuple(RUST_PADDINGS.values()))
    rows = {}
    for label, padding in RUST_PADDINGS.items():
        with tempfile.TemporaryDirectory(prefix=f"ncoh-admission-once-rust-{label}-") as directory:
            wasm = rust_wasm(documents[padding], Path(directory))
            rows[label] = {"bytes": len(documents[padding].encode("utf-8")),
                           "quantity": [rust_amortized(wasm)["quantity"] for _ in range(repeat)]}
    base = rows["n"]["quantity"][0]
    deviation = max(abs(quantity / base - 1) for row in rows.values() for quantity in row["quantity"])
    print(json.dumps({"runs": RUNS, "sizes": rows, "deviation": deviation, "limit": 1 + 5 * deviation}, indent=2, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("languages", nargs="*", default=list(PROBES))
    parser.add_argument("--gleam-threshold", type=float)
    parser.add_argument("--rust-sizes", type=int, metavar="REPEAT")
    options = parser.parse_args()
    if options.rust_sizes is not None:
        return rust_sizes(options.rust_sizes)
    documents = exchanges()
    typed = scenarios([f"pure_typed_{TYPE_PADDING}"])[f"pure_typed_{TYPE_PADDING}"]
    sizes = {padding: len(text.encode("utf-8")) for padding, text in documents.items()}
    typed_size = len(typed.encode("utf-8"))
    if sizes[LARGE_PADDING] < 10 * sizes[SMALL_PADDING] or typed_size < 10 * sizes[SMALL_PADDING]:
        raise SystemExit(f"the large documents are not ten times the small one: {sizes} {typed_size}")
    failures = []
    report = {"document_bytes": {"n": sizes[SMALL_PADDING], "10n": sizes[LARGE_PADDING], "10n-types": typed_size},
              "runs": RUNS, "languages": {}}
    for language in options.languages:
        observed = {}
        for label, padding in (("n", SMALL_PADDING), ("10n", LARGE_PADDING)):
            with tempfile.TemporaryDirectory(prefix=f"ncoh-admission-once-{language}-") as directory:
                if language == "rust" and label == "10n":
                    observed[label] = rust_bounded(rust_wasm(documents[padding], Path(directory)),
                                                   RUST_LIMIT * observed["n"]["quantity"])
                    observed[label]["calls"], observed[label]["init"] = rust_coverage(documents[padding], Path(directory))
                else:
                    observed[label] = PROBES[language](documents[padding], Path(directory))
        if language in TYPE_GROWTH:
            with tempfile.TemporaryDirectory(prefix=f"ncoh-admission-once-{language}-") as directory:
                observed["10n-types"] = PROBES[language](typed, Path(directory))
            failures.extend(f"{failure} (type nodes)" for failure in
                            assess(language, observed["n"], observed["10n-types"], options.gleam_threshold))
        if language == "java":
            typed_java = scenarios([f"pure_typed_{padding}" for padding in JAVA_TYPE_PADDINGS])
            for label, padding in zip(("types-n", "types-10n"), JAVA_TYPE_PADDINGS):
                with tempfile.TemporaryDirectory(prefix="ncoh-admission-once-java-") as directory:
                    observed[label] = java_probe(typed_java[f"pure_typed_{padding}"], Path(directory))
            report["document_bytes"].update({f"java-{label}": len(typed_java[f"pure_typed_{padding}"].encode("utf-8"))
                                             for label, padding in zip(("types-n", "types-10n"), JAVA_TYPE_PADDINGS)})
            failures.extend(f"{failure} (type nodes {JAVA_TYPE_PADDINGS[0]} and {JAVA_TYPE_PADDINGS[1]})" for failure in
                            assess(language, observed["types-n"], observed["types-10n"], options.gleam_threshold))
        report["languages"][language] = observed
        failures.extend(assess(language, observed["n"], observed["10n"], options.gleam_threshold))
    print(json.dumps(report, indent=2, sort_keys=True))
    for failure in failures:
        print(failure, file=sys.stderr)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
