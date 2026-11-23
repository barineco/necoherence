#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check as admission_once

EXPECTED_LINES = {
    "rust": re.compile(r"^pub const SIGNATURE_GENERATION_BASIS:&str=.*;$", re.MULTILINE),
    "python": re.compile(r"^_GENERATION_BASIS = .*$", re.MULTILINE),
    "typescript": re.compile(r"^export const generationBasis: S\.ExpectedSignatureBasis = .*$", re.MULTILINE),
    "java": re.compile(r"^( *)private static String generationBasisText\(\) \{ return .*$", re.MULTILINE),
    "gleam": re.compile(r"^const embedded_basis = .*$", re.MULTILINE),
}
EXTENSIONS = {"rust": "rs", "python": "py", "typescript": "mts", "java": "java", "gleam": "gleam"}
TARGETS = {
    "rust": ["--target", "rust"],
    "python": ["--target", "python"],
    "typescript": ["--target", "typescript", "--runtime", (admission_once.ROOT / "packages/typescript/adapter/src/index.ts").as_uri()],
    "java": ["--target", "java", "--java-package", "", "--java-class", "GeneratedProbe"],
    "gleam": ["--target", "gleam"],
}


def documents() -> tuple[str, str]:
    output = admission_once.command(["cargo", "run", "--locked", "--quiet", "--manifest-path", str(admission_once.EXCHANGE_MANIFEST), "--bin", "generate"],
                                    input_text=json.dumps({"scenarios": ["pure_padded_0", "pure_padded_1"]}))
    values = json.loads(output)
    return values["pure_padded_0"], values["pure_padded_1"]


def artifact(language: str, original: str, replacement: str, scratch: Path) -> str:
    extension = EXTENSIONS[language]
    legitimate, replaced = scratch / f"legitimate.{extension}", scratch / f"replaced.{extension}"
    admission_once.render(TARGETS[language], original, legitimate)
    admission_once.render(TARGETS[language], replacement, replaced)
    expected_line = EXPECTED_LINES[language].search(legitimate.read_text(encoding="utf-8"))
    if expected_line is None:
        raise RuntimeError(f"{language}: the embedded expected basis is absent")
    line = expected_line.group(0)
    if language == "java":
        text = legitimate.with_suffix(".expected.json").read_text(encoding="utf-8")
        line = f"{expected_line.group(1)}private static String generationBasisText() {{ return {json.dumps(text)}; }}"
    source, count = EXPECTED_LINES[language].subn(lambda _: line, replaced.read_text(encoding="utf-8"))
    if count != 1:
        raise RuntimeError(f"{language}: the embedded expected basis appears {count} times")
    return source


RUST_MAIN = """
fn main() {
    match initialize() {
        Err(necoherence::semantic_exchange::GenerationFailure::Admission(failure)) => match *failure {
            necoherence::signature_admission::AdmissionFailure::Certificate(mismatch) => println!("{mismatch}"),
            other => println!("admission {other:?}"),
        },
        Err(other) => println!("generation {other:?}"),
        Ok(_) => println!("admitted"),
    }
}
"""

PYTHON_MAIN = """
import neco_quotient_certificate as quotient
generation = initialize()
if isinstance(generation, InitializeAdmission) and isinstance(generation.failure, _admission.Certificate):
    mismatch = generation.failure.cause
    failed = [condition.value for condition in quotient.Condition if isinstance(mismatch.status_at(condition), quotient.Mismatched)]
    print("admit failed at " + ", ".join(failed))
else:
    print(f"other {generation!r}")
"""


TYPESCRIPT_MAIN = """
import { initialize } from "./replaced.mts";
const CONDITIONS = ["decode", "source", "coordinate", "observations", "digest", "residual"] as const;
const result = initialize();
if (result.tag === "Failed" && result.failure.tag === "Certificate") {
  const mismatch = result.failure.value;
  console.log("admit failed at " + CONDITIONS.filter(condition => mismatch.statusAt(condition).kind === "mismatched").join(", "));
} else {
  console.log(`other ${JSON.stringify(result.tag === "Failed" ? result.failure : result.tag)}`);
}
"""

JAVA_MAIN = """
import java.util.ArrayList;
import java.util.List;

public final class ReplacedMain {
    public static void main(String[] arguments) {
        var result = GeneratedProbe.initialize();
        if (result instanceof GeneratedProbe.InitializeRejected rejected && rejected.failure().mismatch() != null) {
            var mismatch = rejected.failure().mismatch();
            List<String> failed = new ArrayList<>();
            for (neco.quotient.Condition condition : neco.quotient.Condition.values())
                if (mismatch.statusAt(condition) instanceof neco.quotient.Status.Mismatched<?>) failed.add(condition.name().toLowerCase(java.util.Locale.ROOT));
            System.out.println("admit failed at " + String.join(", ", failed));
        } else {
            System.out.println("other " + result);
        }
    }
}
"""

GLEAM_MAIN = """-module(replaced_main).
-export([main/0]).

main() ->
    case generated_probe:initialize() of
        {error, {certificate, Mismatch}} ->
            Failed = [atom_to_list(Condition) || Condition <- [decode, source, coordinate, observations, digest, residual],
                      'neco_quotient_certificate@failure':mismatch_status_at(Mismatch, Condition) =:= mismatched],
            io:format("admit failed at ~s~n", [lists:join(", ", Failed)]);
        Other ->
            io:format("other ~p~n", [Other])
    end.
"""


def typescript_initialize(source: str, scratch: Path) -> str:
    (scratch / "replaced.mts").write_text(source, encoding="utf-8")
    (scratch / "replaced_main.mts").write_text(TYPESCRIPT_MAIN, encoding="utf-8")
    return admission_once.command(["node", "--import", "tsx", str(scratch / "replaced_main.mts")],
                                  cwd=admission_once.ROOT / "packages/typescript/adapter").strip()


def java_initialize(source: str, scratch: Path) -> str:
    library = Path(os.environ.get("NCOH_JAVA_EXECUTION_CLASSPATH", admission_once.ROOT /
                                  "packages/java/adapter/build/maven/io/github/barineco/necoherence/0.3.0/necoherence-0.3.0.jar"))
    sources, classes = scratch / "sources", scratch / "classes"
    sources.mkdir()
    (sources / "GeneratedProbe.java").write_text(source, encoding="utf-8")
    (sources / "ReplacedMain.java").write_text(JAVA_MAIN, encoding="utf-8")
    quotient_sources = sorted(str(source) for root in (os.environ["NCOH_NECO_QUOTIENT_JAVA"], os.environ["NCOH_NECO_QUOTIENT_APPLICATION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_RETENTION_JAVA"], os.environ["NCOH_NECO_QUOTIENT_ENCODING_JAVA"]) for source in Path(root).rglob("*.java"))
    admission_once.command(["javac", "--release", "21", "-cp", str(library), "-d", str(classes),
                            str(sources / "GeneratedProbe.java"), str(sources / "ReplacedMain.java"), *quotient_sources])
    return admission_once.command(["java", "-cp", os.pathsep.join((str(classes), str(library))), "ReplacedMain"]).strip()


def gleam_initialize(source: str) -> str:
    sys.path.insert(0, str(admission_once.EXECUTION))
    import generated_gleam_driver as gleam_cases

    project_root = admission_once.EXECUTION / "generated-packages/replaced-document-gleam"
    shutil.rmtree(project_root, ignore_errors=True)
    project = project_root / "verification/execution/gleam_driver"
    for original, copy in ((admission_once.ROOT / "packages/gleam/adapter", project_root / "packages/gleam/adapter"),
                           (admission_once.EXECUTION / "gleam_driver", project)):
        shutil.copytree(original, copy, ignore=shutil.ignore_patterns("build"))
        gleam_cases.absolutize_external_paths(original, copy)
    gleam_cases.link_build(project)
    shutil.copytree(admission_once.EXECUTION / "gleam_driver/build/packages", project / "build/packages", dirs_exist_ok=True)
    try:
        (project / "src/generated_probe.gleam").write_text(source[source.index(gleam_cases.LICENSE_LINE):], encoding="utf-8")
        (project / "src/replaced_main.erl").write_text(GLEAM_MAIN, encoding="utf-8")
        admission_once.command([os.environ.get("GLEAM", "gleam"), "build"], cwd=project)
        paths = [str(path) for path in (project / "build/dev/erlang").glob("*/ebin")]
        return admission_once.command(["erl", "-noshell", *[argument for path in paths for argument in ("-pa", path)],
                                       "-eval", "replaced_main:main(), halt()."], cwd=project).strip()
    finally:
        shutil.rmtree(project_root, ignore_errors=True)


def rust_initialize(source: str) -> str:
    project = admission_once.EXECUTION / "generated-packages/replaced-document-rust"
    shutil.rmtree(project, ignore_errors=True)
    (project / "src").mkdir(parents=True)
    try:
        (project / "src/main.rs").write_text(source + RUST_MAIN, encoding="utf-8")
        (project / "Cargo.toml").write_text(
            '[package]\nname="replaced-document"\nversion="0.0.0"\nedition="2021"\n\n[workspace]\n\n'
            f'[dependencies]\nnecoherence={{path={json.dumps(str(admission_once.ROOT / "packages/rust/adapter"))}}}\n'
            'serde_json={version="1",features=["arbitrary_precision"]}\n', encoding="utf-8")
        return admission_once.command(["cargo", "run", "--quiet", "--manifest-path", str(project / "Cargo.toml")], cwd=project).strip()
    finally:
        shutil.rmtree(project, ignore_errors=True)


def python_initialize(source: str, scratch: Path) -> str:
    module = scratch / "replaced_main.py"
    module.write_text(source + PYTHON_MAIN, encoding="utf-8")
    environment = {**os.environ, "PYTHONPATH": str(admission_once.ROOT / "packages/python/adapter/src")}
    return admission_once.command([sys.executable, str(module)], env=environment).strip()


def main() -> int:
    original, replacement = documents()
    failures = []
    for language in sys.argv[1:] or list(EXTENSIONS):
        with tempfile.TemporaryDirectory(prefix=f"ncoh-replaced-document-{language}-") as directory:
            scratch = Path(directory)
            source = artifact(language, original, replacement, scratch)
            if language == "rust":
                observed = rust_initialize(source)
            elif language == "python":
                observed = python_initialize(source, scratch)
            elif language == "typescript":
                observed = typescript_initialize(source, scratch)
            elif language == "java":
                observed = java_initialize(source, scratch)
            else:
                observed = gleam_initialize(source)
        print(json.dumps({"language": language, "initialize": observed}))
        failed = observed.removeprefix("admit failed at ").split(":")[0].split(", ") if observed.startswith("admit failed at ") else []
        if not {"source", "coordinate"} & set(failed):
            failures.append(f"{language}: the replaced document is not rejected by the source or coordinate condition: {observed}")
    for failure in failures:
        print(failure, file=sys.stderr)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())
