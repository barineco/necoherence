# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Compare the typed mapping core operations of Lean and Gleam.

The operations are validate, derive_enabled, binding_bound_exceeded,
path_replay and step_at. The inputs are the solver fixtures and inputs
generated from the declaration rules: places, transitions, bindings, graph and
marking are drawn from a small vocabulary, and a share of the references is
replaced by an unknown name so that every invalid reason is reached.
"""

import json
import random
import sys

import check

CASES = check.os.path.join(check.HERE, "core_cases.json")
GENERATED = 3000
NOISE = (0, 5, 15, 40)


def _names(rng, prefix, count, universe, noise):
    names = []
    for _ in range(count):
        index = rng.randrange(universe)
        if rng.randrange(100) < noise:
            index += universe
        names.append("%s%d" % (prefix, index))
    return names


def generate_input(seed):
    rng = random.Random(seed)
    noise = NOISE[seed % len(NOISE)]
    place_count = 1 + rng.randrange(5)
    places = [check._place("p%d" % i, "b" if rng.randrange(6) == 0 else "a")
              for i in range(place_count)]
    transition_count = 1 + rng.randrange(4)
    transitions = []
    for index in range(transition_count):
        identity = "t0" if rng.randrange(100) < noise else "t%d" % index
        transitions.append(check._transition(
            identity,
            _names(rng, "p", rng.randrange(3), place_count, noise),
            _names(rng, "p", rng.randrange(3), place_count, noise)))
        transitions[-1]["failure_places"] = _names(
            rng, "p", rng.randrange(2), place_count, noise)
    bindings = []
    for index, transition in enumerate(transitions):
        for place in transition["input_places"]:
            owner = ("t%d" % (transition_count + 1)
                     if rng.randrange(100) < noise else transition["identity"])
            name = "n0" if rng.randrange(100) < noise else "n%d" % (
                index * 10 + len(bindings))
            binding = check._binding(
                owner, name, place, "x%d" % rng.randrange(3),
                mode=rng.choice(["read", "consume"]),
                multiplicity=rng.randrange(3),
                required_revision=1 + rng.randrange(2))
            binding["token_type"] = "b" if rng.randrange(100) < noise else "a"
            bindings.append(binding)
    for _ in range(rng.randrange(3)):
        bindings.append(check._binding(
            "t%d" % rng.randrange(transition_count + 1),
            "n%d" % rng.randrange(3),
            "p%d" % rng.randrange(place_count + 1),
            "x%d" % rng.randrange(3),
            mode="consume", required_revision=1 + rng.randrange(2)))
    marking = {"places": [
        {"place": "p%d" % rng.randrange(place_count + 1),
         "tokens": [check._token("x%d" % rng.randrange(3),
                                 index=rng.randrange(2),
                                 revision=1 + rng.randrange(2))
                    for _ in range(rng.randrange(4))]}
        for _ in range(rng.randrange(place_count + 2))]}
    return {
        "places": places,
        "transitions": transitions,
        "bindings": bindings,
        "goal": {"kind": "place_has_at_least", "place": "p0", "count": 1},
        "graph": check._graph(
            _names(rng, "p", rng.randrange(3), place_count, noise),
            ["t%d" % rng.randrange(transition_count + 1)
             for _ in range(rng.randrange(3))],
            [["p%d" % rng.randrange(place_count + 1),
              "t%d" % rng.randrange(transition_count + 1)]
             for _ in range(rng.randrange(3))]),
        "marking": marking,
        "bound": check._bound(max_bindings=rng.randrange(9)),
    }


def path_of(rng, input_value):
    names = [t["identity"] for t in input_value["transitions"]] + ["missing"]
    return [rng.choice(names) for _ in range(rng.randrange(5))]


def build_cases():
    cases = []
    rng = random.Random(7)
    for fixture in check.build_fixtures()["cases"]:
        value = fixture["input"]
        cases.append({"name": "fixture:" + fixture["name"], "input": value,
                      "path": path_of(rng, value)})
    for seed in range(1, GENERATED + 1):
        value = generate_input(seed)
        cases.append({"name": "generated:%d" % seed, "input": value,
                      "path": path_of(rng, value)})
    return {"schema": "ncoh-typed-mapping-core/cases@1", "cases": cases}


def prepare():
    document = build_cases()
    with open(CASES, "w", encoding="utf-8") as handle:
        json.dump(document, handle, sort_keys=True)
    print("wrote %s (%d cases)" % (CASES, len(document["cases"])))


def results_of(path):
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    return {entry["case"]: entry["operations"] for entry in document["results"]}


def reach(cases, results):
    valid = sum(1 for r in results.values() if r["validate"]["status"] == "valid")
    reasons = {r["validate"]["reason"]["kind"] for r in results.values()
               if r["validate"]["status"] == "invalid"}
    replayed = sum(1 for r in results.values() if r["path_replay"] is not None)
    stepped = sum(1 for r in results.values()
                  if any(step is not None for step in r["step_at"]))
    return valid, reasons, replayed, stepped


def compare(lean_path, gleam_path):
    with open(CASES, "r", encoding="utf-8") as handle:
        cases = json.load(handle)["cases"]
    lean = results_of(lean_path)
    gleam = results_of(gleam_path)
    names = [case["name"] for case in cases]
    if sorted(lean) != sorted(names) or sorted(gleam) != sorted(names):
        print("core_compare: FAIL: result sets differ from the cases", file=sys.stderr)
        return 1
    differences = [name for name in names if lean[name] != gleam[name]]
    if differences:
        name = differences[0]
        print("core_compare: FAIL: %d differences, first %s\nlean: %s\ngleam: %s"
              % (len(differences), name, json.dumps(lean[name])[:2000],
                 json.dumps(gleam[name])[:2000]), file=sys.stderr)
        return 1
    valid, reasons, replayed, stepped = reach(cases, lean)
    if valid == 0 or len(reasons) < 8 or replayed == 0 or stepped == 0:
        print("core_compare: FAIL: generated inputs miss the rules (valid=%d reasons=%d replayed=%d stepped=%d)"
              % (valid, len(reasons), replayed, stepped), file=sys.stderr)
        return 1
    print("core_compare: lean == gleam over %d cases (valid %d, invalid reasons %d, replayed %d, stepped %d)"
          % (len(names), valid, len(reasons), replayed, stepped))
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--prepare"]:
        prepare()
    elif len(sys.argv) == 4 and sys.argv[1] == "--compare":
        sys.exit(compare(sys.argv[2], sys.argv[3]))
    else:
        print("usage: core_compare.py --prepare | --compare <lean.json> <gleam.json>", file=sys.stderr)
        sys.exit(2)
