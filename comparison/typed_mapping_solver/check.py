#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORKTREE = os.path.abspath(os.path.join(HERE, "..", ".."))
FIXTURES = os.path.join(HERE, "fixtures.json")
ORACLE = os.path.join(HERE, "oracle.py")

TOOLS_DIR = os.path.join(WORKTREE, "tools")
LEAN_DIR = os.path.join(TOOLS_DIR, "lean")
RUST_DIR = os.path.join(TOOLS_DIR, "rust")
GLEAM_DIR = os.path.join(TOOLS_DIR, "gleam")



PUBLIC_MODULES = {
    "lean": "NecoherenceTools.TypedMappingSolver",
    "rust": "necoherence_tools::typed_mapping_solver",
    "gleam": "necoherence_tools/typed_mapping_solver",
}

MODULE_TOKENS = {
    "lean": ["import NecoherenceTools.TypedMappingSolver"],
    "rust": ["necoherence_tools::typed_mapping_solver"],
    "gleam": ["necoherence_tools/typed_mapping_solver"],
}

RUNNER_FILES = {
    "lean": os.path.join(HERE, "lean_runner.lean"),
    "rust": os.path.join(RUST_DIR, "examples",
                         "typed_mapping_solver_compare.rs"),
    "gleam": os.path.join(GLEAM_DIR, "src",
                          "typed_mapping_solver_compare.gleam"),
}

TEST_FILES = {
    "lean": os.path.join(LEAN_DIR, "NecoherenceToolsTests",
                         "TypedMappingSolverTest.lean"),
    "rust": os.path.join(RUST_DIR, "tests",
                         "typed_mapping_solver_tests.rs"),
    "gleam": os.path.join(GLEAM_DIR, "test",
                          "typed_mapping_solver_test.gleam"),
}


class CheckFailure(Exception):
    pass


def fail(message):
    raise CheckFailure(message)


def emit_json(document, path):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=1, sort_keys=True)
        handle.write("\n")


def load_json(path, what):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        fail("%s missing: %s" % (what, path))
    except json.JSONDecodeError as exc:
        fail("%s is not valid JSON: %s (%s)" % (what, path, exc))


def run(argv, cwd=None, env=None, stdin_path=None, timeout=None):
    env_full = dict(os.environ)
    if env:
        env_full.update(env)
    stdin = open(stdin_path, "r", encoding="utf-8") if stdin_path else None
    try:
        completed = subprocess.run(
            argv, cwd=cwd, env=env_full, stdin=stdin,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, check=False)
        stdout = completed.stdout.decode("utf-8", "replace")
        stderr = completed.stderr.decode("utf-8", "replace")
        return {"argv": argv, "cwd": cwd or os.getcwd(), "timed_out": False,
                "exit_code": completed.returncode,
                "stdout": stdout, "stderr": stderr,
                "stdout_tail": stdout[-4000:], "stderr_tail": stderr[-4000:]}
    except subprocess.TimeoutExpired:
        return {"argv": argv, "cwd": cwd or os.getcwd(), "timed_out": True,
                "exit_code": None, "stdout": "", "stderr": "",
                "stdout_tail": "", "stderr_tail": ""}
    finally:
        if stdin is not None:
            stdin.close()


def extract_json(text, what):
    start = text.find("{")
    if start < 0:
        fail("%s produced no JSON object on stdout" % what)
    try:
        value, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as exc:
        fail("%s produced unparseable JSON: %s" % (what, exc))
    return value


def git(repository, *args):
    completed = subprocess.run(
        ["git", "-C", repository] + list(args),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return completed.returncode, \
        completed.stdout.decode("utf-8", "replace"), \
        completed.stderr.decode("utf-8", "replace")


def parse_kv_pairs(values, what):
    out = {}
    for item in values or []:
        if "=" not in item:
            fail("malformed %s pair %r (expected name=value)" % (what, item))
        name, _, value = item.partition("=")
        out[name] = value
    return out







def _place(identity, token_type="tok", revision=1):
    return {"identity": identity, "token_type": token_type,
            "revision": revision}


def _transition(identity, inputs, outputs, revision=1):
    return {"identity": identity, "input_places": inputs,
            "output_places": outputs, "failure_places": [],
            "revision": revision}


def _binding(transition_id, name, place, identity, mode="consume",
             token_type="tok", multiplicity=1, required_revision=1):
    return {"transition_id": transition_id, "name": name, "place": place,
            "token_type": token_type, "identity": identity,
            "provenance": "decl", "multiplicity": multiplicity, "mode": mode,
            "required_revision": required_revision}


def _token(target, index=0, revision=1, kind="input"):
    return {"target": target, "index": index, "revision": revision,
            "kind": kind}


def _graph(places, transitions, edges):
    return {"places": places, "transitions": transitions, "edges": edges,
            "revision": 1}


def _bound(max_bindings=8, max_search_steps=8):
    return {"target_identity": "unit:typed-mapping-solver", "index": 0,
            "revision": 1, "max_bindings": max_bindings,
            "max_search_steps": max_search_steps}


def _baseline_input():
    return {
        "places": [_place("p1"), _place("p2"), _place("p-dead")],
        "transitions": [_transition("t1", ["p1"], ["p2"]),
                        _transition("t-dead", ["p-dead"], ["p2"])],
        "bindings": [_binding("t1", "b1", "p1", "res-a"),
                     _binding("t-dead", "b2", "p-dead", "res-dead")],
        "goal": {"kind": "place_has_at_least", "place": "p2", "count": 1},
        "graph": _graph(["p1", "p2", "p-dead"], ["t1", "t-dead"],
                        [["p1", "t1"], ["t1", "p2"],
                         ["p-dead", "t-dead"], ["t-dead", "p2"]]),
        "marking": {"places": [{"place": "p1",
                                "tokens": [_token("res-a")]},
                               {"place": "p2", "tokens": []},
                               {"place": "p-dead", "tokens": []}]},
        "bound": _bound(),
    }


def _expected_invalid(kind, **fields):
    return {
        operation: {"status": "invalid",
                    "reason": dict({"kind": kind}, **fields)}
        for operation in ("derive_enabled", "check_reachability",
                          "check_deadlock", "check_well_foundedness")
    }


def _exact_closing_cycle_input():
    places = [_place("p-seed"), _place("p-token")]
    transitions = [
        _transition("t-consume", ["p-token"], []),
        _transition("t-add", ["p-seed"], ["p-token"]),
    ]
    bindings = [
        _binding("t-consume", "b-token", "p-token", "t-add"),
        _binding("t-add", "b-seed", "p-seed", "res-seed",
                 mode="read"),
    ]
    return {
        "places": places,
        "transitions": transitions,
        "bindings": bindings,
        "goal": {"kind": "place_has_at_least", "place": "p-seed",
                 "count": 1},
        "graph": _graph(
            ["p-seed", "p-token"], ["t-consume", "t-add"],
            [["p-token", "t-consume"], ["p-seed", "t-add"],
             ["t-add", "p-token"]]),
        "marking": {"places": [
            {"place": "p-seed", "tokens": [_token("res-seed")]},
            {"place": "p-token", "tokens": []},
        ]},
        "bound": _bound(),
    }


def build_fixtures():
    baseline = _baseline_input()

    deadlocked = json.loads(json.dumps(baseline))
    deadlocked["marking"] = {"places": [{"place": "p1", "tokens": []},
                                        {"place": "p2", "tokens": []},
                                        {"place": "p-dead", "tokens": []}]}

    unreachable = json.loads(json.dumps(baseline))
    unreachable["goal"] = {"kind": "place_has_at_least", "place": "p2",
                           "count": 5}

    exhausted = json.loads(json.dumps(baseline))
    exhausted["bound"]["max_search_steps"] = 0

    invalid = json.loads(json.dumps(baseline))
    invalid["bindings"][0]["token_type"] = "T-OTHER"

    loop = {
        "places": [_place("p2")],
        "transitions": [_transition("t2", ["p2"], [])],
        "bindings": [_binding("t2", "b2", "p2", "res-b", mode="read")],
        "goal": {"kind": "place_has_at_least", "place": "p2", "count": 99},
        "graph": _graph(["p2"], ["t2"], [["p2", "t2"], ["t2", "p2"]]),
        "marking": {"places": [{"place": "p2",
                                "tokens": [_token("res-b")]}]},
        "bound": _bound(),
    }

    goal_initial = json.loads(json.dumps(baseline))
    goal_initial["goal"] = {"kind": "place_has_at_least", "place": "p1",
                            "count": 1}
    goal_initial["bound"]["max_search_steps"] = 0

    ghost = json.loads(json.dumps(baseline))
    ghost["transitions"][0]["input_places"] = ["GHOST"]
    ghost["bindings"] = []

    missing_binding = json.loads(json.dumps(baseline))
    missing_binding["bindings"] = [missing_binding["bindings"][1]]

    duplicate = json.loads(json.dumps(baseline))
    duplicate["transitions"].append(
        json.loads(json.dumps(duplicate["transitions"][0])))

    exact_cycle = _exact_closing_cycle_input()

    return {"schema": "ncoh-typed-mapping-solver/fixtures@1",
            "cases": [
                {"name": "baseline-reachable", "input": baseline},
                {"name": "deadlocked-empty", "input": deadlocked},
                {"name": "unreachable-goal", "input": unreachable},
                {"name": "bound-exhausted", "input": exhausted},
                {"name": "invalid-type", "input": invalid},
                {"name": "self-loop-not-well-founded", "input": loop},
                {"name": "goal-satisfied-initial", "input": goal_initial,
                 "expected": {
                     "check_reachability": {
                         "status": "reachable", "path": []}}},
                {"name": "input-place-membership", "input": ghost,
                 "expected": _expected_invalid(
                     "unknown_input_place", transition_id="t1",
                     place="GHOST")},
                {"name": "missing-binding", "input": missing_binding,
                 "expected": _expected_invalid(
                     "missing_input_binding", transition_id="t1",
                     place="p1")},
                {"name": "duplicate-transition-identity", "input": duplicate,
                 "expected": _expected_invalid(
                     "duplicate_transition_identity", identity="t1")},
                {"name": "decreasing-closing-cycle", "input": exact_cycle,
                 "expected": {
                     "check_well_foundedness": {
                         "status": "not_well_founded",
                         "witness": {
                             "prefix_path": [],
                             "cycle_path": ["t-add", "t-consume"],
                             "cycle_start": {"places": [
                                 {"place": "p-seed",
                                  "tokens": [_token("res-seed")]},
                                 {"place": "p-token", "tokens": []}]},
                             "cycle_end": {"places": [
                                 {"place": "p-seed",
                                  "tokens": [_token("res-seed")]},
                                 {"place": "p-token", "tokens": []}]},
                             "measure_decreasing": True}}}},
            ]}


def cmd_prepare_fixtures(_args):
    emit_json(build_fixtures(), FIXTURES)
    print("wrote %s (%d cases)" % (FIXTURES,
                                   len(build_fixtures()["cases"])))







def check_module_alignment():
    rc, head, _ = git(WORKTREE, "rev-parse", "HEAD")
    if rc != 0:
        fail("cannot resolve implementation worktree revision")
    revision = head.strip()
    for language in ("lean", "rust", "gleam"):
        runner = RUNNER_FILES[language]
        test = TEST_FILES[language]
        for path, label in ((runner, "runner"), (test, "test")):
            if not os.path.isfile(path):
                fail("missing %s %s: %s" % (language, label, path))
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
            if not any(token in text for token in MODULE_TOKENS[language]):
                fail("%s %s does not reference public module %s"
                     % (language, label, PUBLIC_MODULES[language]))
    return revision


def run_oracle_full(fixtures_path):
    completed = subprocess.run(
        [sys.executable, ORACLE, "--fixtures", fixtures_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if completed.returncode != 0:
        fail("oracle failed on %s: %s"
             % (fixtures_path,
                completed.stderr.decode("utf-8", "replace")[-2000:]))
    return json.loads(completed.stdout.decode("utf-8"))


def results_map(document, producer):
    results = document.get("results")
    if not isinstance(results, list):
        fail("producer %s document lacks a 'results' list" % producer)
    return {entry["case"]: entry["operations"] for entry in results}


def _assert_expected(actual, expected, path):
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            fail("%s expected object, got %r" % (path, actual))
        for key, value in expected.items():
            if key not in actual:
                fail("%s lacks expected field %s" % (path, key))
            _assert_expected(actual[key], value, "%s.%s" % (path, key))
        return
    if actual != expected:
        fail("%s expected %r, got %r" % (path, expected, actual))


def check_expected_fixture_results(fixtures, oracle_document):
    expected_by_case = {
        case["name"]: case.get("expected", {})
        for case in fixtures.get("cases", [])
    }
    actual_by_case = results_map(oracle_document, "oracle")
    for case, expected in expected_by_case.items():
        if not expected:
            continue
        if case not in actual_by_case:
            fail("oracle lacks expected fixture case %s" % case)
        _assert_expected(actual_by_case[case], expected,
                         "expected[%s]" % case)


def check_witness_shapes(fixtures, oracle_document):
    inputs = {case["name"]: case["input"]
              for case in fixtures.get("cases", [])}
    for case, operations in results_map(oracle_document, "oracle").items():
        spec = inputs.get(case)
        if spec is None:
            fail("oracle returned an undeclared fixture case %s" % case)
        reachability = operations["check_reachability"]
        if reachability.get("status") == "unreachable":
            witness = reachability.get("closure_witness")
            if not isinstance(witness, dict) \
                    or not isinstance(witness.get("explored_markings"), list) \
                    or not isinstance(witness.get("steps"), int) \
                    or witness.get("frontier") != []:
                fail("fixture %s has an incomplete closure witness" % case)
            if witness["steps"] != len(witness["explored_markings"]) \
                    or witness["steps"] > spec["bound"]["max_search_steps"]:
                fail("fixture %s has invalid closure witness steps" % case)
        well_foundedness = operations["check_well_foundedness"]
        if well_foundedness.get("status") == "well_founded":
            witness = well_foundedness.get("witness")
            if not isinstance(witness, dict) \
                    or not isinstance(witness.get("explored_markings"), list) \
                    or not isinstance(witness.get("steps"), int) \
                    or witness.get("frontier") != []:
                fail("fixture %s has an incomplete acyclic witness" % case)
            if witness["steps"] != len(witness["explored_markings"]) \
                    or witness["steps"] > spec["bound"]["max_search_steps"]:
                fail("fixture %s has invalid acyclic witness steps" % case)
        if well_foundedness.get("status") == "not_well_founded":
            witness = well_foundedness.get("witness")
            if not isinstance(witness, dict) \
                    or not isinstance(witness.get("prefix_path"), list) \
                    or not isinstance(witness.get("cycle_path"), list) \
                    or not witness["cycle_path"] \
                    or witness.get("cycle_start") != witness.get("cycle_end"):
                fail("fixture %s has an incomplete cycle witness" % case)


def compare_results(named_docs):
    names = list(named_docs)
    base = results_map(named_docs[names[0]], names[0])
    for other in names[1:]:
        theirs = results_map(named_docs[other], other)
        if set(base) != set(theirs):
            fail("case sets differ between %s and %s" % (names[0], other))
        for case, ops in base.items():
            if ops != theirs[case]:
                fail("producer %s disagrees with %s on case %s: %s != %s"
                     % (other, names[0], case, json.dumps(ops)[:200],
                        json.dumps(theirs[case])[:200]))







def cmd_compare_public_producers(args):
    producers = parse_kv_pairs(args.compare_public_producers, "producer")
    for language in ("lean", "rust", "gleam"):
        if language not in producers:
            fail("missing producer output for %s" % language)
    named_docs = {}
    for language, rel in producers.items():
        path = rel if os.path.isabs(rel) else os.path.join(HERE, rel)
        document = load_json(path, "producer output %s" % language)
        kind = document.get("producer_kind")
        if args.reject_local_producers and kind in ("local", None):
            fail("producer %s is not a public-module producer (kind=%r)"
                 % (language, kind))
        if args.reject_test_only_producers and kind in ("test-only", None):
            fail("producer %s is a test-only producer (kind=%r)"
                 % (language, kind))
        if kind != "public-api":
            fail("producer %s has unrecognized producer_kind %r"
                 % (language, kind))
        module = document.get("solver_module")
        if module != PUBLIC_MODULES.get(language):
            fail("producer %s used module %r, expected public module %r"
                 % (language, module, PUBLIC_MODULES.get(language)))
        named_docs[language] = document



    fixture_document = load_json(FIXTURES, "fixtures")
    oracle_doc = run_oracle_full(FIXTURES)
    check_expected_fixture_results(fixture_document, oracle_doc)
    check_witness_shapes(fixture_document, oracle_doc)
    named_docs["oracle"] = oracle_doc
    compare_results(named_docs)
    print("producer agreement: lean == rust == gleam == oracle over %d cases"
          % len(results_map(oracle_doc, "oracle")))

    revision = check_module_alignment()
    for entry in args.require_same_public_solver or []:
        if entry not in ("lean-runtime-test", "rust-runtime-test",
                         "gleam-runtime-test"):
            fail("unknown --require-same-public-solver entry %r" % entry)
    print("runner/test public-module alignment verified at revision %s"
          % revision)







def invoke_language_engines(fixtures_path):
    engines = {"oracle": run_oracle_full(fixtures_path)}

    env = {"TMS_FIXTURES": os.path.abspath(fixtures_path)}
    lean = run(["lake", "env", "lean", RUNNER_FILES["lean"]],
               cwd=LEAN_DIR, env=env, timeout=600)
    if lean["exit_code"] != 0:
        fail("lean runner failed: %s%s"
             % (lean["stderr_tail"], lean["stdout_tail"]))
    engines["lean-checker"] = extract_json(lean["stdout"], "lean runner")

    rust = run(["cargo", "run", "--quiet", "--example",
                "typed_mapping_solver_compare", "--",
                os.path.abspath(fixtures_path)],
               cwd=RUST_DIR, timeout=900)
    if rust["exit_code"] != 0:
        fail("rust runner failed: %s%s"
             % (rust["stderr_tail"], rust["stdout_tail"]))
    engines["rust-public-api"] = extract_json(rust["stdout"], "rust runner")

    gleam = run(["gleam", "run", "-m", "typed_mapping_solver_compare", "--",
                 os.path.abspath(fixtures_path)],
                cwd=GLEAM_DIR, timeout=900)
    if gleam["exit_code"] != 0:
        fail("gleam runner failed: %s%s"
             % (gleam["stderr_tail"], gleam["stdout_tail"]))
    engines["gleam-public-api"] = extract_json(gleam["stdout"],
                                               "gleam runner")

    tests = {
        "lean-runtime-test": run(
            ["lake", "env", "lean",
             "NecoherenceToolsTests/TypedMappingSolverTest.lean"],
            cwd=LEAN_DIR, timeout=600),
        "rust-runtime-test": run(
            ["cargo", "test", "--test", "typed_mapping_solver_tests"],
            cwd=RUST_DIR, timeout=900),
        "gleam-runtime-test": run(["gleam", "test"], cwd=GLEAM_DIR,
                                  timeout=900),
    }
    for name, outcome in tests.items():
        if outcome["exit_code"] != 0:
            fail("%s failed: %s%s"
                 % (name, outcome["stderr_tail"], outcome["stdout_tail"]))
        engines[name] = {"producer_kind": "runtime-test",
                         "test_passed": True,
                         "exit_code": outcome["exit_code"]}
    return engines


def check_oracle_independence(oracle_path):
    with open(oracle_path, "r", encoding="utf-8") as handle:
        source = handle.read()
    for function in ("derive_enabled", "check_reachability",
                     "check_deadlock", "check_well_foundedness"):
        if not re.search(r"def (op_)?%s\b" % function, source):
            fail("oracle %s does not define its own %s"
                 % (oracle_path, function))
    forbidden = ("TypedMappingSolver.lean", "typed_mapping_solver.rs",
                 "typed_mapping_solver.gleam", "necoherence/typed_mapping_solver",
                 "necoherence::typed_mapping_solver",
                 "Necoherence.TypedMappingSolver",
                 "necoherence_tools/typed_mapping_solver",
                 "necoherence_tools::typed_mapping_solver",
                 "NecoherenceTools.TypedMappingSolver",
                 "TypedMapping.lean", "typed_mapping.rs",
                 "typed_mapping.gleam", "necoherence/typed_mapping",
                 "necoherence::typed_mapping", "Necoherence.TypedMapping")
    for token in forbidden:
        if token in source:
            fail("oracle %s references producer source %r: the oracle must "
                 "be independently defined" % (oracle_path, token))
    for other in ("tools/lean/NecoherenceTools/TypedMappingSolver.lean",
                  "tools/rust/src/typed_mapping_solver.rs",
                  "tools/gleam/src/necoherence_tools/typed_mapping_solver.gleam",
                  "lean/Necoherence/TypedMapping.lean",
                  "rust/src/typed_mapping.rs",
                  "gleam/src/necoherence/typed_mapping.gleam"):
        full = os.path.join(WORKTREE, other)
        if os.path.isfile(full):
            with open(full, "rb") as handle:
                digest = hashlib.sha256(handle.read()).hexdigest()
            if hashlib.sha256(source.encode("utf-8")).hexdigest() == digest:
                fail("oracle %s is byte-identical to producer %s"
                     % (oracle_path, other))


def cmd_mutation_classification(args):
    fixtures = load_json(args.fixtures, "fixtures")
    cases = {c["name"]: c["input"] for c in fixtures["cases"]}
    mutation_doc = load_json(args.mutation_results, "mutation results")
    mutants = mutation_doc.get("mutants")
    if not isinstance(mutants, list) or not mutants:
        fail("mutation results %s lacks a non-empty 'mutants' list"
             % args.mutation_results)
    base_name = mutation_doc.get("base_case")
    if base_name not in cases:
        fail("mutation results base_case %r not present in fixtures"
             % base_name)
    base_input = cases[base_name]

    for coordinate in args.require_coordinate or []:
        if not any(m.get("coordinate") == coordinate for m in mutants):
            fail("required mutation coordinate %r has no mutants"
                 % coordinate)

    check_oracle_independence(args.oracle)


    mutant_cases = [{"name": m["id"], "input": m["mutated_input"]}
                    for m in mutants]
    mutant_doc = {"schema": "ncoh-typed-mapping-solver/fixtures@1",
                  "cases": [{"name": "__base__", "input": base_input}]
                    + mutant_cases}
    tmp = tempfile.NamedTemporaryFile(
        "w", suffix=".json", prefix="tms-mutants-",
        dir=HERE, delete=False, encoding="utf-8")
    try:
        json.dump(mutant_doc, tmp)
        tmp.close()
        engines = invoke_language_engines(tmp.name)
    finally:
        os.unlink(tmp.name)

    check_witness_shapes(mutant_doc, engines["oracle"])

    required_entries = set(args.require_independent_entry or [])
    for entry in required_entries:
        if entry not in engines:
            fail("independent entry %r was not invoked" % entry)

    producer_maps = {name: results_map(engines[name], name)
                     for name in ("oracle", "lean-checker",
                                  "rust-public-api", "gleam-public-api")}
    if args.reject_candidate_only_agreement and "oracle" not in producer_maps:
        fail("candidate-only agreement: the independent oracle was not "
             "invoked")
    base_results = producer_maps["oracle"]["__base__"]
    for name, mapping in producer_maps.items():
        if mapping.get("__base__") != base_results:
            fail("%s disagrees with oracle on the unmutated base case"
                 % name)

    invalidating = 0
    preserving = 0
    bound_exhausted = 0
    for mutant in mutants:
        mid = mutant["id"]
        coordinate = mutant.get("coordinate")
        cls = mutant.get("class")
        for name, mapping in producer_maps.items():
            if mid not in mapping:
                fail("engine %s produced no result for mutant %s"
                     % (name, mid))
        agreement = [producer_maps[name][mid] for name in
                     ("oracle", "lean-checker", "rust-public-api",
                      "gleam-public-api")]
        for name, result in zip(("oracle", "lean-checker", "rust-public-api",
                                 "gleam-public-api"), agreement):
            if result != agreement[0]:
                fail("engine %s disagrees with oracle on mutant %s"
                     % (name, mid))
        observed = agreement[0]
        statuses = {op: observed[op]["status"] for op in observed}
        if cls == "invalidating":
            invalidating += 1
            if args.require_invalidating_result == "Invalid":
                bad = {op: s for op, s in statuses.items()
                       if s != "invalid"}
                if bad:
                    fail("invalidating mutant %s produced %s instead of "
                         "Invalid" % (mid, bad))
        elif cls == "meaning-preserving":
            preserving += 1
            if args.require_preserving_result_equality:
                if observed != base_results:
                    fail("meaning-preserving mutant %s changed results"
                         % mid)
        elif cls == "bound-exhausted":
            bound_exhausted += 1
            expected = args.require_bound_exhaustion_result or "Unknown"
            for op in ("check_reachability", "check_well_foundedness"):
                if statuses[op] != expected.lower():
                    fail("bound-exhausted mutant %s produced %s for %s, "
                         "expected %s" % (mid, statuses[op], op, expected))
        if args.require_unreachable_closure_witness:
            for op, result in observed.items():
                if result.get("status") == "unreachable":
                    witness = result.get("closure_witness")
                    if not isinstance(witness, dict) \
                            or not isinstance(
                                witness.get("explored_markings"), list) \
                            or not isinstance(witness.get("steps"), int):
                        fail("unreachable result for mutant %s/%s lacks a "
                             "closure witness" % (mid, op))
        recorded = mutant.get("oracle_result")
        if recorded is not None and recorded != observed:
            fail("mutation runner recorded oracle result for %s does not "
                 "match re-observation" % mid)
        _ = coordinate

    if invalidating == 0:
        fail("no invalidating mutants classified")
    if preserving == 0:
        fail("no meaning-preserving mutants classified")
    print("mutation classification verified: %d mutants (%d invalidating, "
          "%d meaning-preserving, %d bound-exhausted); oracle, independent "
          "lean checker, rust/gleam public APIs and runtime/test entries "
          "all invoked independently and in agreement"
          % (len(mutants), invalidating, preserving, bound_exhausted))







def build_parser():
    parser = argparse.ArgumentParser(
        prog="check.py",
        description="typed mapping solver comparison coordinator")
    parser.add_argument("--prepare-fixtures", action="store_true")
    parser.add_argument("--compare-public-producers", nargs="+",
                        metavar="LANG=FILE")
    parser.add_argument("--require-same-public-solver", nargs="*")
    parser.add_argument("--reject-local-producers", action="store_true")
    parser.add_argument("--reject-test-only-producers",
                        action="store_true")

    parser.add_argument("--mutation-classification", action="store_true")
    parser.add_argument("--fixtures")
    parser.add_argument("--mutation-results")
    parser.add_argument("--oracle")
    parser.add_argument("--lean-runner")
    parser.add_argument("--rust-runner")
    parser.add_argument("--gleam-runner")
    parser.add_argument("--lean-test")
    parser.add_argument("--rust-test")
    parser.add_argument("--gleam-test")
    parser.add_argument("--require-coordinate", action="append")
    parser.add_argument("--require-invalidating-result")
    parser.add_argument("--require-preserving-result-equality",
                        action="store_true")
    parser.add_argument("--require-bound-exhaustion-result")
    parser.add_argument("--require-unreachable-closure-witness",
                        action="store_true")
    parser.add_argument("--require-independent-entry", action="append")
    parser.add_argument("--reject-shared-oracle-implementation",
                        action="store_true")
    parser.add_argument("--reject-candidate-only-agreement",
                        action="store_true")
    return parser


def main(argv):
    parser = build_parser()
    args, _unknown = parser.parse_known_args(argv)
    if _unknown:
        fail("unrecognized arguments: %s" % " ".join(_unknown))
    try:
        if args.prepare_fixtures:
            cmd_prepare_fixtures(args)
        elif args.compare_public_producers is not None:
            cmd_compare_public_producers(args)
        elif args.mutation_classification:
            for needed in ("fixtures", "mutation_results", "oracle",
                           "lean_runner", "rust_runner", "gleam_runner",
                           "lean_test", "rust_test", "gleam_test"):
                if getattr(args, needed) is None:
                    fail("--mutation-classification requires --%s"
                         % needed.replace("_", "-"))
            cmd_mutation_classification(args)
        else:
            fail("no mode selected")
    except CheckFailure as exc:
        print("check.py: FAIL: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
