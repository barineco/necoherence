#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT


import json
import sys
from collections import deque

OPS = ("derive_enabled", "check_reachability", "check_deadlock",
       "check_well_foundedness")






def tokens_at(marking, place):
    for entry in marking["places"]:
        if entry["place"] == place:
            return entry["tokens"]
    return []


def eval_goal(marking, goal):
    kind = goal["kind"]
    if kind == "place_has_at_least":
        return len(tokens_at(marking, goal["place"])) >= goal["count"]
    if kind == "place_has_token":
        return any(
            t["target"] == goal["target"]
            and t["index"] == goal["index"]
            and t["revision"] == goal["revision"]
            for t in tokens_at(marking, goal["place"]))
    if kind == "and":
        return eval_goal(marking, goal["a"]) and eval_goal(marking, goal["b"])
    if kind == "or":
        return eval_goal(marking, goal["a"]) or eval_goal(marking, goal["b"])
    if kind == "not":
        return not eval_goal(marking, goal["a"])
    raise ValueError("unknown goal kind: %r" % kind)


def _find(seq, pred):
    for item in seq:
        if pred(item):
            return item
    return None







def _structure_fault(spec, binding):
    transitions = spec["transitions"]
    places = spec["places"]
    if not any(t["identity"] == binding["transition_id"] for t in transitions):
        return {"kind": "unknown_transition",
                "transition_id": binding["transition_id"]}
    if not any(p["identity"] == binding["place"] for p in places):
        return {"kind": "unknown_place", "place": binding["place"]}
    transition = _find(
        transitions, lambda t: t["identity"] == binding["transition_id"])
    if binding["place"] not in transition["input_places"]:
        return {"kind": "dependency_mismatch",
                "transition_id": binding["transition_id"],
                "place": binding["place"]}
    declared = _find(places, lambda p: p["identity"] == binding["place"])
    if declared["token_type"] != binding["token_type"]:
        return {"kind": "type_mismatch", "place": binding["place"],
                "expected": binding["token_type"],
                "actual": declared["token_type"]}
    if binding["multiplicity"] == 0:
        return {"kind": "multiplicity_mismatch",
                "transition_id": binding["transition_id"],
                "name": binding["name"], "expected": 1, "actual": 0}
    twins = [b for b in spec["bindings"]
             if b["transition_id"] == binding["transition_id"]
             and b["name"] == binding["name"]]
    if len(twins) > 1:
        return {"kind": "identity_mismatch",
                "transition_id": binding["transition_id"],
                "name": binding["name"]}
    return None


def _revision_fault(spec, binding):
    bad = _find(
        tokens_at(spec["marking"], binding["place"]),
        lambda t: t["target"] == binding["identity"]
        and t["revision"] != binding["required_revision"])
    if bad is None:
        return None
    return {"kind": "revision_mismatch",
            "transition_id": binding["transition_id"],
            "name": binding["name"],
            "expected": binding["required_revision"],
            "actual": bad["revision"]}


def _branch_place_fault(spec):
    declared_places = {p["identity"] for p in spec["places"]}
    for transition in spec["transitions"]:
        for place in transition["output_places"] + transition["failure_places"]:
            if place not in declared_places:
                return {"kind": "dependency_mismatch",
                        "transition_id": transition["identity"],
                        "place": place}
    return None


def _input_place_fault(spec):
    declared = {p["identity"] for p in spec["places"]}
    for transition in spec["transitions"]:
        for place in transition["input_places"]:
            if place not in declared:
                return {"kind": "unknown_input_place",
                        "transition_id": transition["identity"],
                        "place": place}
    return None


def _duplicate_transition_fault(spec):
    seen = set()
    for transition in spec["transitions"]:
        identity = transition["identity"]
        if identity in seen:
            return {"kind": "duplicate_transition_identity",
                    "identity": identity}
        seen.add(identity)
    return None


def _missing_binding_fault(spec):
    for transition in spec["transitions"]:
        input_places = transition["input_places"]
        if not input_places:
            continue
        bound_places = {
            binding["place"] for binding in spec["bindings"]
            if binding["transition_id"] == transition["identity"]
        }
        for place in input_places:
            if place not in bound_places:
                return {"kind": "missing_input_binding",
                        "transition_id": transition["identity"],
                        "place": place}
    return None


def validate(spec):
    fault = _input_place_fault(spec)
    if fault is not None:
        return fault
    fault = _duplicate_transition_fault(spec)
    if fault is not None:
        return fault
    fault = _missing_binding_fault(spec)
    if fault is not None:
        return fault
    for binding in spec["bindings"]:
        fault = _structure_fault(spec, binding)
        if fault is not None:
            return fault
    for binding in spec["bindings"]:
        fault = _revision_fault(spec, binding)
        if fault is not None:
            return fault
    declared_places = {p["identity"] for p in spec["places"]}
    for pid in spec["graph"]["places"]:
        if pid not in declared_places:
            return {"kind": "unknown_place", "place": pid}
    declared_transitions = {t["identity"] for t in spec["transitions"]}
    for tid in spec["graph"]["transitions"]:
        if tid not in declared_transitions:
            return {"kind": "unknown_transition", "transition_id": tid}
    nodes = set(spec["graph"]["places"]) | set(spec["graph"]["transitions"])
    for edge in spec["graph"]["edges"]:
        if edge[0] not in nodes or edge[1] not in nodes:
            return {"kind": "dependency_mismatch",
                    "transition_id": edge[0], "place": edge[1]}
    return _branch_place_fault(spec)









def bindings_for(spec, transition_id):
    return [b for b in spec["bindings"] if b["transition_id"] == transition_id]


def binding_satisfied_at(marking, binding):
    matching = [t for t in tokens_at(marking, binding["place"])
                if t["target"] == binding["identity"]
                and t["revision"] == binding["required_revision"]]
    return len(matching) >= binding["multiplicity"]


def transition_enabled_at(bindings, marking):
    return all(binding_satisfied_at(marking, b) for b in bindings)


def enabled_transitions(spec, marking):
    out = []
    for transition in spec["transitions"]:
        bound = bindings_for(spec, transition["identity"])
        if transition_enabled_at(bound, marking):
            out.append({"transition_id": transition["identity"],
                        "bindings": bound})
    return out


def _select_matching(tokens, binding):
    picked = []
    for token in tokens:
        if (token["target"] == binding["identity"]
                and token["revision"] == binding["required_revision"]):
            if len(picked) >= binding["multiplicity"]:
                break
            picked.append(token)
    return picked


def consumed_at(bindings, marking, place):
    consumed = []
    for binding in bindings:
        if binding["place"] == place and binding["mode"] == "consume":
            consumed.extend(
                _select_matching(tokens_at(marking, place), binding))
    return consumed


def _drop_one(tokens, token):
    remaining = []
    dropped = False
    for current in tokens:
        if not dropped and current == token:
            dropped = True
            continue
        remaining.append(current)
    return remaining


def apply_consumption(marking, bindings):
    places = []
    for entry in marking["places"]:
        kept = list(entry["tokens"])
        for doomed in consumed_at(bindings, marking, entry["place"]):
            kept = _drop_one(kept, doomed)
        places.append({"place": entry["place"], "tokens": kept})
    return {"places": places}


def _add_token(marking, place, token):
    names = [e["place"] for e in marking["places"]]
    if place in names:
        out = []
        for entry in marking["places"]:
            if entry["place"] == place:
                out.append({"place": place,
                            "tokens": [token] + entry["tokens"]})
            else:
                out.append({"place": entry["place"],
                            "tokens": list(entry["tokens"])})
        return {"places": out}
    places = [{"place": e["place"], "tokens": list(e["tokens"])}
              for e in marking["places"]]
    places.append({"place": place, "tokens": [token]})
    return {"places": places}


def produced_token(transition):
    return {"target": transition["identity"], "index": 0,
            "revision": transition["revision"], "kind": "output"}


def apply_branch_at(marking, transition, bindings):
    result = apply_consumption(marking, bindings)
    token = produced_token(transition)
    for place in transition["output_places"]:
        result = _add_token(result, place, token)
    return result







def _neighbors(spec, path, marking):
    out = []
    for transition in spec["transitions"]:
        bound = bindings_for(spec, transition["identity"])
        if transition_enabled_at(bound, marking):
            out.append((path + [transition["identity"]],
                        apply_branch_at(marking, transition, bound)))
    return out


def _fresh(neighbors, blocked):
    kept = []
    seen = list(blocked)
    for pair in neighbors:
        if pair[1] in seen:
            continue
        kept.append(pair)
        seen.append(pair[1])
    return kept


def explore(spec):
    fuel = spec["bound"]["max_search_steps"]
    frontier = deque([([], spec["marking"])])
    visited = []
    while frontier:
        path, marking = frontier[0]
        if fuel == 0:
            if eval_goal(marking, spec["goal"]):
                return ("found", path, marking)
            return ("bound_hit", [marking] + visited)
        frontier.popleft()
        if eval_goal(marking, spec["goal"]):
            return ("found", path, marking)
        visited = [marking] + visited
        blocked = visited + [pending for _, pending in frontier]
        frontier.extend(
            _fresh(_neighbors(spec, path, marking), blocked))
        fuel -= 1
    return ("closed", visited)


def _total_tokens(marking):
    return sum(len(e["tokens"]) for e in marking["places"])


def explore_cycles(spec):
    fuel = spec["bound"]["max_search_steps"]
    stack = [([], [spec["marking"]], spec["marking"])]
    explored = []
    while stack:
        path, active, marking = stack.pop()
        if fuel == 0:
            return ("bound_hit", explored)
        if marking in explored:
            continue
        neighbors = _neighbors(spec, path, marking)
        for npath, nmarking in neighbors:
            if nmarking in active:
                start_index = active.index(nmarking)
                return (
                    "cycle",
                    path[:start_index],
                    npath[start_index:],
                    nmarking,
                    nmarking,
                    _total_tokens(nmarking) < _total_tokens(marking),
                )
        explored = [marking] + explored
        blocked = active + explored
        fresh = [(npath, active + [nmarking], nmarking)
                 for npath, nmarking in _fresh(neighbors, blocked)]
        stack.extend(reversed(fresh))
        fuel -= 1
    return ("closed", explored)







def _binding_bound_exceeded(spec):
    candidates = sum(
        len(bindings_for(spec, transition["identity"]))
        for transition in spec["transitions"])
    return spec["bound"]["max_bindings"] < candidates


def _binding_exhausted(spec):
    return {"status": "unknown",
            "reason": {"kind": "binding_bound_exhausted",
                       "limit": spec["bound"]["max_bindings"]}}


def op_derive_enabled(spec):
    fault = validate(spec)
    if fault is not None:
        return {"status": "invalid", "reason": fault}
    return {"status": "enabled_set",
            "enabled": enabled_transitions(spec, spec["marking"])}


def op_check_reachability(spec):
    fault = validate(spec)
    if fault is not None:
        return {"status": "invalid", "reason": fault}
    if _binding_bound_exceeded(spec):
        return _binding_exhausted(spec)
    outcome = explore(spec)
    if outcome[0] == "found":
        return {"status": "reachable", "path": outcome[1],
                "final_marking": outcome[2]}
    if outcome[0] == "closed":
        visited = outcome[1]
        return {"status": "unreachable",
                "closure_witness": {"explored_markings": visited,
                                    "steps": len(visited), "frontier": []}}
    return {"status": "unknown",
            "reason": {"kind": "search_step_bound_exhausted",
                       "limit": spec["bound"]["max_search_steps"]}}


def op_check_deadlock(spec):
    fault = validate(spec)
    if fault is not None:
        return {"status": "invalid", "reason": fault}
    if _binding_bound_exceeded(spec):
        return _binding_exhausted(spec)
    enabled = enabled_transitions(spec, spec["marking"])
    if eval_goal(spec["marking"], spec["goal"]):
        return {"status": "not_deadlocked", "enabled": enabled}
    if not enabled:
        return {"status": "deadlocked", "marking": spec["marking"]}
    return {"status": "not_deadlocked", "enabled": enabled}


def op_check_well_foundedness(spec):
    fault = validate(spec)
    if fault is not None:
        return {"status": "invalid", "reason": fault}
    if _binding_bound_exceeded(spec):
        return _binding_exhausted(spec)
    outcome = explore_cycles(spec)
    if outcome[0] == "cycle":
        _, prefix, cycle, start, end, decreasing = outcome
        return {"status": "not_well_founded",
                "witness": {
                    "prefix_path": prefix,
                    "cycle_path": cycle,
                    "cycle_start": start,
                    "cycle_end": end,
                    "measure_decreasing": decreasing,
                }}
    if outcome[0] == "closed":
        explored = outcome[1]
        return {"status": "well_founded",
                "witness": {
                    "explored_markings": explored,
                    "steps": len(explored),
                    "frontier": [],
                }}
    return {"status": "unknown",
            "reason": {"kind": "search_step_bound_exhausted",
                       "limit": spec["bound"]["max_search_steps"]}}


def evaluate(spec):
    return {
        "derive_enabled": op_derive_enabled(spec),
        "check_reachability": op_check_reachability(spec),
        "check_deadlock": op_check_deadlock(spec),
        "check_well_foundedness": op_check_well_foundedness(spec),
    }







def _fail(message):
    print("oracle: %s" % message, file=sys.stderr)
    sys.exit(1)


def main(argv):
    if len(argv) != 2 or argv[0] not in ("--fixtures", "--input"):
        _fail("usage: oracle.py --fixtures <path> | --input <path>")
    mode, path = argv
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        _fail("cannot load %s: %s" % (path, exc))
    if mode == "--fixtures":
        cases = document.get("cases")
        if not isinstance(cases, list):
            _fail("fixtures document lacks a 'cases' list")
        results = [{"case": case["name"], "operations": evaluate(case["input"])}
                   for case in cases]
        print(json.dumps({
            "producer": "oracle",
            "solver_module": "independent-python-oracle",
            "producer_kind": "oracle",
            "results": results,
        }, indent=1, sort_keys=True))
    else:
        if "input" in document:
            name = document.get("name", "input")
            spec = document["input"]
        else:
            name = "input"
            spec = document
        print(json.dumps({"case": name, "operations": evaluate(spec)},
                         indent=1, sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1:])
