#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Mutation generator, executor and classifier for the typed mapping solver.

Reads the shared fixtures document, derives a mutation family per declared
coordinate (binding-type, multiplicity, read-consume-mode, identity, index,
revision, graph-edge, input-binding, token, domain-bound), evaluates every
mutant through the independently defined oracle (invoked as a separate
process), and writes the versioned classification to the requested output.

Classification vocabulary:

  invalidating        every operation reports the closed Invalid result
  meaning-preserving  every operation result equals the unmutated base result
  bound-exhausted     reachability and well-foundedness report Unknown
  result-changing     some operation changed without becoming Invalid

The runner refuses to write results when a mutant's observed class differs
from the class its generator predicted, or when a --require-class name has
no member. `check.py --mutation-classification` re-verifies the whole
classification against every engine independently.
"""

import argparse
import copy
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ORACLE = os.path.join(HERE, "oracle.py")

COORDINATES = ("binding-type", "multiplicity", "read-consume-mode",
               "identity", "index", "revision", "graph-edge",
               "input-binding", "token", "domain-bound",
               "input-place-membership", "binding-coverage",
               "cycle-closing-decrease")


def fail(message):
    print("mutation_runner: FAIL: %s" % message, file=sys.stderr)
    sys.exit(1)


def oracle_evaluate(spec):
    """Evaluate one solver input through the independent oracle process."""
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json",
                                      prefix="tms-mutant-", dir=HERE,
                                      delete=False, encoding="utf-8")
    try:
        json.dump({"name": "mutant", "input": spec}, tmp)
        tmp.close()
        completed = subprocess.run(
            [sys.executable, ORACLE, "--input", tmp.name],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if completed.returncode != 0:
            fail("oracle failed on a mutant: %s"
                 % completed.stderr.decode("utf-8", "replace")[-2000:])
        return json.loads(completed.stdout.decode("utf-8"))["operations"]
    finally:
        os.unlink(tmp.name)


def classify(observed, base):
    statuses = {op: observed[op].get("status") for op in observed}
    if all(s == "invalid" for s in statuses.values()):
        return "invalidating"
    if observed == base:
        return "meaning-preserving"
    if statuses.get("check_reachability") == "unknown" \
            and statuses.get("check_well_foundedness") == "unknown":
        return "bound-exhausted"
    return "result-changing"


# ---------------------------------------------------------------------------
# mutation family
# ---------------------------------------------------------------------------


def _fresh(base):
    return copy.deepcopy(base)




def _cycle_input():
    return {
        "places": [
            {"identity": "p-seed", "token_type": "tok", "revision": 1},
            {"identity": "p-token", "token_type": "tok", "revision": 1},
        ],
        "transitions": [
            {"identity": "t-consume", "input_places": ["p-token"],
             "output_places": [], "failure_places": [], "revision": 1},
            {"identity": "t-add", "input_places": ["p-seed"],
             "output_places": ["p-token"], "failure_places": [],
             "revision": 1},
        ],
        "bindings": [
            {"transition_id": "t-consume", "name": "b-token",
             "place": "p-token", "token_type": "tok", "identity": "t-add",
             "provenance": "decl", "multiplicity": 1, "mode": "consume",
             "required_revision": 1},
            {"transition_id": "t-add", "name": "b-seed",
             "place": "p-seed", "token_type": "tok", "identity": "res-seed",
             "provenance": "decl", "multiplicity": 1, "mode": "read",
             "required_revision": 1},
        ],
        "goal": {"kind": "place_has_at_least", "place": "p-seed",
                 "count": 1},
        "graph": {"places": ["p-seed", "p-token"],
                  "transitions": ["t-consume", "t-add"],
                  "edges": [["p-token", "t-consume"],
                            ["p-seed", "t-add"], ["t-add", "p-token"]],
                  "revision": 1},
        "marking": {"places": [
            {"place": "p-seed", "tokens": [
                {"target": "res-seed", "index": 0, "revision": 1,
                 "kind": "input"}]},
            {"place": "p-token", "tokens": []},
        ]},
        "bound": {"target_identity": "unit:typed-mapping-solver",
                  "index": 0, "revision": 1,
                  "max_bindings": 8, "max_search_steps": 8},
    }
def mutation_family(base):
    """(id, coordinate, predicted class, mutated input) for the base case."""
    mutants = []

    def add(mid, coordinate, expected, input_, description):
        mutants.append({"id": mid, "coordinate": coordinate,
                        "expected_class": expected,
                        "description": description,
                        "mutated_input": input_})

    # --- binding-type ---------------------------------------------------
    m = _fresh(base)
    m["bindings"][0]["token_type"] = "T-OTHER"
    add("mut-binding-type-mismatch", "binding-type", "invalidating", m,
        "binding token_type no longer matches the declared place type")

    m = _fresh(base)
    for place in m["places"]:
        if place["identity"] == "p-dead":
            place["token_type"] = "tok-x"
    for binding in m["bindings"]:
        if binding["place"] == "p-dead":
            binding["token_type"] = "tok-x"
    add("mut-binding-type-consistent-rename", "binding-type",
        "meaning-preserving", m,
        "place and binding token types renamed consistently on the "
        "never-enabled t-dead branch")

    # --- multiplicity ----------------------------------------------------
    m = _fresh(base)
    m["bindings"][0]["multiplicity"] = 0
    add("mut-multiplicity-zero", "multiplicity", "invalidating", m,
        "binding multiplicity set to zero")

    m = _fresh(base)
    m["bindings"][1]["multiplicity"] = 3
    add("mut-multiplicity-disabled", "multiplicity", "meaning-preserving",
        m, "multiplicity raised on the never-enabled t-dead binding")

    # --- read-consume-mode -------------------------------------------------
    m = _fresh(base)
    m["bindings"][1]["mode"] = "read"
    add("mut-mode-disabled", "read-consume-mode", "meaning-preserving", m,
        "read/consume mode flipped on the never-enabled t-dead binding")

    m = _fresh(base)
    m["bindings"][0]["mode"] = "read"
    add("mut-mode-enabled", "read-consume-mode", "result-changing", m,
        "consume changed to read on the enabled t1 binding: the token is "
        "retained, so firing produces a different marking")

    # --- identity ----------------------------------------------------------
    m = _fresh(base)
    m["transitions"][0]["identity"] = "t1-renamed"
    add("mut-identity-unknown-transition", "identity", "invalidating", m,
        "transition identity renamed while bindings and graph still "
        "reference the old name")

    m = _fresh(base)
    m["bindings"][1]["name"] = "b-dead-renamed"
    add("mut-identity-binding-name", "identity", "meaning-preserving", m,
        "binding name renamed on the never-enabled t-dead branch")

    m = _fresh(base)
    m["transitions"].append(copy.deepcopy(m["transitions"][0]))
    add("mut-identity-duplicate-transition", "identity", "invalidating", m,
        "a transition identity is declared twice")

    # --- index -------------------------------------------------------------
    m = _fresh(base)
    m["marking"]["places"][0]["tokens"][0]["index"] = 7
    add("mut-index-token", "index", "result-changing", m,
        "colored token index changes the exact marking witness")

    # --- revision ------------------------------------------------------------
    m = _fresh(base)
    m["marking"]["places"][0]["tokens"][0]["revision"] = 2
    add("mut-revision-token", "revision", "invalidating", m,
        "marked token revision diverges from the binding's required "
        "revision")

    m = _fresh(base)
    m["bound"]["revision"] = 2
    add("mut-revision-bound", "revision", "meaning-preserving", m,
        "domain bound revision bumped; bound metadata is not part of the "
        "search semantics")

    # --- graph-edge ----------------------------------------------------------
    m = _fresh(base)
    m["graph"]["edges"][0] = ["p1", "ghost-node"]
    add("mut-graph-edge-ghost", "graph-edge", "invalidating", m,
        "dependency edge endpoint is not a declared graph node")

    m = _fresh(base)
    m["graph"]["edges"].append(["p2", "t-dead"])
    add("mut-graph-edge-extra", "graph-edge", "meaning-preserving", m,
        "extra edge between two declared nodes; the graph is validated "
        "but not consulted by the search")

    # --- input-binding ---------------------------------------------------------
    m = _fresh(base)
    m["bindings"].append(dict(m["bindings"][0]))
    add("mut-input-binding-duplicate", "input-binding", "invalidating", m,
        "duplicate binding name within one transition")

    m = _fresh(base)
    m["bindings"].append({
        "transition_id": "t-dead", "name": "b3", "place": "p-dead",
        "token_type": "tok", "identity": "res-dead", "provenance": "decl",
        "multiplicity": 1, "mode": "read", "required_revision": 1})
    add("mut-input-binding-extra", "input-binding", "meaning-preserving", m,
        "extra binding on the never-enabled t-dead branch")

    # --- input-place-membership -----------------------------------------------
    m = _fresh(base)
    m["transitions"][0]["input_places"] = ["GHOST"]
    m["bindings"] = []
    add("mut-input-place-ghost", "input-place-membership", "invalidating", m,
        "an undeclared input place is introduced with no bindings")

    # --- binding-coverage ------------------------------------------------------
    m = _fresh(base)
    m["bindings"] = [b for b in m["bindings"] if b["transition_id"] != "t1"]
    add("mut-binding-coverage-missing", "binding-coverage", "invalidating", m,
        "a declared input place loses every binding")

    # --- token -----------------------------------------------------------------
    m = _fresh(base)
    m["marking"]["places"][0]["tokens"][0]["kind"] = "observation"
    add("mut-token-kind", "token", "result-changing", m,
        "token kind changes the exact marking witness")

    m = _fresh(base)
    m["marking"]["places"][0]["tokens"][0]["target"] = "res-x"
    add("mut-token-target", "token", "result-changing", m,
        "token target changed; the t1 binding is no longer satisfied")

    # --- domain-bound --------------------------------------------------------------
    m = _fresh(base)
    m["bound"]["max_search_steps"] = 0
    add("mut-bound-steps-zero", "domain-bound", "bound-exhausted", m,
        "search-step bound exhausted with a nonempty frontier")

    m = _fresh(base)
    m["bound"]["max_bindings"] = 64
    add("mut-bound-bindings", "domain-bound", "meaning-preserving", m,
        "binding bound raised; the declared finite domain already fits")

    m = _fresh(base)
    m["bound"]["max_bindings"] = 0
    add("mut-bound-bindings-exhausted", "domain-bound", "bound-exhausted",
        m, "binding bound decreased to zero; the declared finite domain "
        "no longer fits, so evaluation reports bound exhaustion")

    m = _fresh(base)
    m["bound"]["target_identity"] = "unit:OTHER"
    add("mut-bound-target", "domain-bound", "meaning-preserving", m,
        "domain bound target identity changed; it is descriptive metadata")

    # --- cycle-closing-decrease -----------------------------------------------
    add("mut-cycle-closing-decrease", "cycle-closing-decrease",
        "result-changing", _cycle_input(),
        "an additive edge followed by a consuming edge returns to the "
        "exact initial marking with a decreasing closing measure")

    return mutants


def main(argv):
    parser = argparse.ArgumentParser(prog="mutation_runner.py")
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--coordinate", action="append")
    parser.add_argument("--require-class", action="append")
    args = parser.parse_args(argv)

    fixtures_path = args.fixtures \
        if os.path.isabs(args.fixtures) else os.path.abspath(args.fixtures)
    with open(fixtures_path, "r", encoding="utf-8") as handle:
        fixtures = json.load(handle)
    cases = {c["name"]: c["input"] for c in fixtures.get("cases", [])}
    base_name = "baseline-reachable"
    if base_name not in cases:
        fail("fixtures document lacks the %r base case" % base_name)
    base_input = cases[base_name]
    base_result = oracle_evaluate(base_input)

    wanted = set(args.coordinate or COORDINATES)
    for coordinate in wanted:
        if coordinate not in COORDINATES:
            fail("unknown mutation coordinate %r" % coordinate)

    mutants = [m for m in mutation_family(base_input)
               if m["coordinate"] in wanted]
    for coordinate in wanted:
        if not any(m["coordinate"] == coordinate for m in mutants):
            fail("coordinate %r produced no mutants" % coordinate)

    results = []
    for mutant in mutants:
        observed = oracle_evaluate(mutant["mutated_input"])
        observed_class = classify(observed, base_result)
        if observed_class != mutant["expected_class"]:
            fail("mutant %s expected class %r but observed %r"
                 % (mutant["id"], mutant["expected_class"], observed_class))
        results.append({
            "id": mutant["id"],
            "coordinate": mutant["coordinate"],
            "class": observed_class,
            "expected_class": mutant["expected_class"],
            "description": mutant["description"],
            "bound_exhausted": observed_class == "bound-exhausted",
            "mutated_input": mutant["mutated_input"],
            "oracle_result": observed,
        })

    classes = {m["class"] for m in results}
    for required in args.require_class or []:
        if required not in classes:
            fail("required mutant class %r was not generated" % required)

    document = {
        "schema": "ncoh-typed-mapping-solver/mutation-results@1",
        "base_case": base_name,
        "fixtures": os.path.basename(fixtures_path),
        "coordinates": sorted(wanted),
        "base_result": base_result,
        "mutants": results,
    }
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print("wrote %s: %d mutants over %d coordinates (%s)"
          % (args.output, len(results), len(wanted),
             ", ".join(sorted(classes))))


if __name__ == "__main__":
    main(sys.argv[1:])
