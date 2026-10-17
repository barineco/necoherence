#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

REPO = Path(__file__).resolve().parents[2]
ALLOWED = ("Classical.choice", "Quot.sound", "propext")
SORRY = "sorryAx"
TIMEOUT = 3000

REQUIRED_THEOREMS = {
    "Necoherence.SemanticValidation": (
        "required_absent_rejected",
        "nonnullable_null_rejected",
        "materialized_value_member",
        "projection_member_sound",
        "projectionSlotsSound",
        "member_certificate_sound",
        "valueMember_path_irrelevant",
        "alias_closed_has_no_member",
        "formatRuleIncluded_sound",
        "formatAccepts_literal",
        "formatAccepts_optional",
        "formatAccepts_sequence_nil",
        "formatAccepts_sequence_cons",
        "formatAccepts_labels",
        "formatAccepts_bounded",
        "sealedFieldFailureRejects",
        "sealedValuePreserved",
        "sealedStringFormatFailureRejects",
        "sealedIntegerMaximumFailureRejects",
        "graphemeBoundariesEmpty",
        "graphemeBoundariesInvariant",
        "graphemeLengthFromBoundaries",
    ),
    "Necoherence.SemanticComposition": (
        "inclusionWitnessSound",
        "emptyTypesSound",
        "counterexampleWitnessSound",
        "resourceWitnessSound",
        "resourceClosureSound",
        "resourceAcyclicSound",
        "resourceLoweringSimulation",
        "sourceBindingSemanticSound",
        "suppliedBindingSemanticSound",
        "compositionBindingSound",
        "compositionBranchSound",
        "compositionGoalReachable",
        "checkedWitnessSound",
        "uniqueSelectionSound",
        "compositionClosureSound",
        "compositionRankSound",
        "bindingSourceConstraintSound",
        "constructionFieldConstraintSound",
        "constructionRequiredFieldSound",
    ),
    "Necoherence.SemanticCodec": ("constructedMember",),
    "NecoherenceTools.SemanticRenderer": ("generatedCompositionSound",),
    "Necoherence.SemanticProfile": (
        "graphemeTableChecksumSound",
        "graphemeDecodeChecksumSound",
    ),
    "Necoherence.TypeSignatures": (
        "signatureStructureSound",
        "signatureReferencesSound",
        "signatureBaseOutcomesPreserved",
        "signatureOutcomeCoverageSound",
        "externalOutcomeCoverageSound",
        "signatureMetadataOrthogonality",
    ),
    "Necoherence.SignatureGeneration": (
        "signatureBasisSound",
        "signatureWireMetadataOrthogonality",
    ),
    "Necoherence.SignatureComposition": (
        "signatureExternalInvocationCovered",
    ),
}
REQUIRED_DEFINITIONS = {
    "Necoherence.SemanticValidation": ("checkProjectionCertificate",),
    "Necoherence.SemanticComposition": ("verifyInclusion", "verifyCounterexample", "verifyCompositionCandidate", "verifyComposition"),
    "NecoherenceTools.CompositionSearch": ("derive",),
    "Necoherence.SemanticCodec": ("construct",),
    "NecoherenceTools.SemanticRenderer": ("renderChecked",),
    "Necoherence.SemanticExecution": ("execute",),
    "Necoherence.SemanticNetwork": ("call",),
    "Necoherence.SignatureGeneration": ("admit",),
    "NecoherenceTools.SignatureGeneration": ("generate",),
    "Necoherence.SignatureComposition": ("verifyInput",),
    "NecoherenceTools.SignatureComposition": ("generate",),
    "NecoherenceTools.TypeSignatures": ("generate",),
}
TOOLS_ONLY_DECLARATIONS = (
    "Necoherence.SemanticComposition.derive",
    "Necoherence.SemanticRenderer.renderChecked",
    "Necoherence.SemanticRenderer.generatedCompositionSound",
    "Necoherence.SignatureGeneration.generate",
    "Necoherence.SignatureComposition.generate",
    "Necoherence.TypeSignatures.generate",
)
MODULES = (
    "Necoherence.SemanticTypes",
    "Necoherence.SemanticValidation",
    "Necoherence.SemanticComposition",
    "Necoherence.SemanticProfile",
    "Necoherence.SemanticCodec",
    "Necoherence.TypeSignatures",
    "Necoherence.SignatureGeneration",
    "Necoherence.SignatureComposition",
    "Necoherence.SemanticExecution",
    "Necoherence.SemanticNetwork",
)
TOOLS_MODULES = (
    "NecoherenceTools.CompositionSearch",
    "NecoherenceTools.SemanticRenderer",
    "NecoherenceTools.SignatureGeneration",
)
ALL_MODULES = MODULES + TOOLS_MODULES

LEAN_LISTING = r"""@IMPORTS@
import Lean
open Lean

#eval show CoreM Unit from do
  let env ← getEnv
  let mut count := 0
  for module in [@MODULE_NAMES@] do
    let some index := env.header.moduleNames.findIdx? (· == module) | throwError "module not loaded"
    let some data := env.header.moduleData[index]? | throwError "module data missing"
    for info in data.constants do
      let kind? : Option String := match info with
        | .thmInfo _ => some "THM"
        | .defnInfo _ => some "DEF"
        | _ => none
      if let some kind := kind? then
        let axioms ← collectAxioms info.name
        IO.println s!"CONST\t{kind}\t{info.name}\t{",".intercalate (axioms.toList.map toString)}"
        count := count + 1
  IO.println s!"END\t{count}"
"""


class Failure(Exception):
    def __init__(self, kind: str, reason: str, offending: Optional[List[dict]] = None,
                 missing: Optional[List[str]] = None) -> None:
        super().__init__(reason)
        self.kind = kind
        self.reason = reason
        self.offending = offending or []
        self.missing = missing or []


def run_lake(arguments: Sequence[str], lean_dir: Path, kind: str) -> str:
    try:
        done = subprocess.run(["lake", *arguments], cwd=str(lean_dir), capture_output=True,
                              text=True, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Failure(kind, "lake did not run: " + type(error).__name__)
    if done.returncode != 0:
        raise Failure(kind, "lake " + " ".join(arguments[:2]) + " exited with " + str(done.returncode))
    return done.stdout


def list_constants(lean_dir: Path, tools_dir: Path) -> List[Tuple[str, str, Tuple[str, ...]]]:
    for directory in (lean_dir, tools_dir):
        if not (directory / "lakefile.toml").is_file():
            raise Failure("BuildFailed", "no lakefile.toml in " + str(directory.relative_to(REPO)))
    run_lake(["build", *MODULES], lean_dir, "BuildFailed")
    run_lake(["build", *TOOLS_MODULES], tools_dir, "BuildFailed")
    with tempfile.TemporaryDirectory() as scratch:
        source = Path(scratch) / "listing.lean"
        source.write_text(
            LEAN_LISTING.replace("@IMPORTS@", "\n".join("import " + module for module in ALL_MODULES))
            .replace("@MODULE_NAMES@", ", ".join("`" + module for module in ALL_MODULES)),
            encoding="utf-8",
        )
        output = run_lake(["env", "lean", str(source)], tools_dir, "LeanFailed")
    found: Dict[str, Tuple[str, Tuple[str, ...]]] = {}
    ends: List[int] = []
    for line in output.split("\n"):
        fields = line.split("\t")
        if fields[0] == "CONST" and len(fields) == 4 and fields[1] in ("THM", "DEF") and fields[2]:
            found.setdefault(fields[2], (fields[1], tuple(sorted(a for a in fields[3].split(",") if a))))
        elif fields[0] == "END" and len(fields) == 2 and fields[1].isdigit():
            ends.append(int(fields[1]))
        elif fields[0] in ("CONST", "END"):
            raise Failure("UninterpretableOutput", "malformed line from the listing")
    if len(ends) != 1 or ends[0] != len(found):
        raise Failure("UninterpretableOutput", "the listing has no consistent end line")
    return sorted((name, kind, axioms) for name, (kind, axioms) in found.items())


def required_names() -> List[Tuple[str, str]]:
    names = [(module + "." + short, "THM") for module, shorts in REQUIRED_THEOREMS.items() for short in shorts]
    names += [(module + "." + short, "DEF") for module, shorts in REQUIRED_DEFINITIONS.items() for short in shorts]
    return names


def judge(constants: List[Tuple[str, str, Tuple[str, ...]]]) -> dict:
    if not constants:
        raise Failure("EmptyEnumeration", "the modules have no theorem or definition")
    lingering = [{"name": name, "kind": kind, "axioms": list(axioms)} for name, kind, axioms in constants if name in TOOLS_ONLY_DECLARATIONS]
    if lingering:
        raise Failure("ToolsDeclarationInMitModule", "declarations that belong to tools/lean are present in lean/", lingering)
    entries = [{"name": name, "kind": kind, "axioms": list(axioms)} for name, kind, axioms in constants]
    offending = [e for e in entries if any(a not in ALLOWED for a in e["axioms"])]
    kinds = {name: kind for name, kind, _ in constants}
    missing = [name for name, kind in required_names() if kinds.get(name) != kind]
    if any(SORRY in e["axioms"] for e in offending):
        raise Failure("SorryAxiom", "declarations depend on " + SORRY, offending, missing)
    if offending:
        raise Failure("DisallowedAxiom", "declarations depend on axioms outside the allowed set", offending, missing)
    if missing:
        raise Failure("MissingProperty", "required declarations are absent", [], missing)
    required = {name for name, _ in required_names()}
    return {
        "ok": True,
        "modules": list(ALL_MODULES),
        "allowed_axioms": list(ALLOWED),
        "theorem_count": sum(1 for e in entries if e["kind"] == "THM"),
        "definition_count": sum(1 for e in entries if e["kind"] == "DEF"),
        "sorry_count": 0,
        "disallowed_count": 0,
        "required": [e for e in entries if e["name"] in required],
    }


def check(lean_dir: Path, tools_dir: Path) -> dict:
    try:
        return judge(list_constants(lean_dir, tools_dir))
    except Failure as failure:
        return {
            "ok": False,
            "modules": list(ALL_MODULES),
            "failure": failure.kind,
            "reason": failure.reason,
            "offending": failure.offending,
            "missing": failure.missing,
        }


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description="axioms of the theorems and definitions of the semantic modules")
    parser.add_argument("--lean-dir", default=str(REPO / "lean"))
    parser.add_argument("--tools-lean-dir", default=str(REPO / "tools" / "lean"))
    options = parser.parse_args(list(argv))
    result = check(Path(options.lean_dir).resolve(), Path(options.tools_lean_dir).resolve())
    sys.stdout.write(json.dumps(result, sort_keys=True, ensure_ascii=False) + "\n")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
