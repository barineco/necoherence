# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: AGPL-3.0-only

"""Deterministic mutation inputs for the signature admission comparison.

Every input is derived from one base exchange by editing its JSON tree. A node is the root, an
object field value, or an array element. The families of edits are:

- single: one node replaced by null, a number, an empty string, an empty array, an empty object,
  or `{"tag":"Bogus"}`; one extra key added to an object node; one field deleted.
- natural: a node that holds a natural number string replaced by "-1", "256", "4294967296", or
  "18446744073709551616".
- extra-name: one extra key added to an object node, named after a key of the sibling fields or
  after a name that the wire records use.
- decimal-text: a node that holds an exact JSON value (Bool, Null, Integer, Decimal, String, Array) replaced by a
  Decimal whose text is a spelling of the exponent, sign, leading zero, space, or long mantissa family.
- canonical: a string leaf under entrypoints, provenance, sources, groups, annotations, or composition replaced
  by a string with control characters, quotes, a backslash, a slash, U+2028, U+2029, or a character outside the
  BMP, or by a raw number in one of the spellings that the digest text of Lean writes in one form. The first
  leaf of each region takes every value; the other leaf shapes take a subset.
- pair: two edits at once on two sibling fields of one record, or on one field and one extra key.

The inputs of a position shape (the path with every array index replaced by `*`) and the sequence of
the `tag` values of the objects on the path are represented by the first position in document order of
the first base that has them. Each edit is written with the digests of the basis derived again from the edited exchange, so that
the checks after the certificate see the edited exchange; the expected basis of such an input
carries the same digests, so that the certificate agrees. The single and natural families are also
written with the declared digests left stale, which the certificate must report. An edit under `basis`, and an edit that no digest
depends on, is written once with the declared digests.
"""

from __future__ import annotations

import copy
import dataclasses
import hashlib
import json
import re
from dataclasses import dataclass
from typing import Iterator

NATURAL = re.compile(r"^(0|[1-9][0-9]*)$")
NATURAL_VALUES = ("-1", "256", "4294967296", "18446744073709551616")
WIRE_NAMES = ("cause", "basis", "type_ref")
VALUE_EDITS = (
    ("null", None),
    ("number", 5),
    ("empty-string", ""),
    ("empty-array", []),
    ("empty-object", {}),
    ("bogus-tag", {"tag": "Bogus"}),
    ("keyed-object", {"zz": 1}),
)
PAIR_COMBINATIONS = (
    (("bogus-tag", {"tag": "Bogus"}), ("number", 5)),
    (("number", 5), ("bogus-tag", {"tag": "Bogus"})),
)
JSON_VALUE_TAGS = ("Bool", "Null", "Integer", "Decimal", "String", "Array", "Object")
DECIMAL_TEXTS = (
    "1e10000", "1e-10000", "1E+10000", "1e9999", "1e-9999", "1e99999999999", "1e-99999999999",
    "1e4294967296", "1e4294967295", "-1e10000", "01", "-01", "+1", " 1", "1 ", " 1 ", "1.", "-0", "-", "",
    "0.0e0", "1.5e3", "1" * 400, "0." + "0" * 400 + "1",
)
DIGEST_REGIONS = (("entrypoints",), ("signatures", "provenance"), ("signatures", "sources"),
                  ("signatures", "groups"), ("signatures", "annotations"), ("composition",))
CONTROL_STRINGS = tuple(chr(code) for code in range(0x20)) + ("\x7f",)
OTHER_STRINGS = ("\u2028", "\u2029", '"', "\\", "/", "\U0001f600", "\u00e9", 'a"b\\c/d\n\t\x00\x7f')
NUMBER_SPELLINGS = ("1.0", "10e-1", "100.0", "2.00", "0.10e1", "7.0e-0", "1.0e1", "25e-1", "0.50", "1e-1",
                    "10.10", "123.000e-2", "-0.0", "0e5", "1E2", "1e9999", "1e10000", "1e-9999", "1e-10000",
                    "1e10001", "1e99999999999")
REDUCED_STRINGS = ("\n", "\t", "\x00", "\x7f", "\u2028", '"', "\\", "/", "\U0001f600")
REDUCED_NUMBERS = ("1.0", "100.0", "2.00", "1E2", "-0.0", "0e5", "25e-1", "10.10")
EXTRA_PAIR_EDITS = (("bogus-tag", {"tag": "Bogus"}),)
STALE_FAMILIES = ("single", "natural")
DIGEST_FIELDS = ("graph_sha256", "provenance_sha256", "metadata_sha256", "entrypoints_sha256")


@dataclass(frozen=True)
class Edit:
    path: tuple
    action: str
    value: object = None


@dataclass(frozen=True)
class Mutation:
    family: str
    shape: str
    position: str
    description: str
    edits: tuple[Edit, ...]
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class ExhaustiveInput:
    base: str
    mutation: Mutation
    recomputed: bool
    request: str

    @property
    def name(self) -> str:
        state = "recomputed" if self.recomputed else "stale"
        return f"exhaustive/{self.base}/{self.mutation.family}/{state}/{self.mutation.shape}/" \
               f"{self.mutation.description}@{self.mutation.position}"


@dataclass(frozen=True)
class RawNumber:
    """A JSON number kept in its written spelling."""

    spelling: str


EXPONENT_LIMIT = 10000
NUMBER_GRAMMAR = re.compile(r"^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?)([0-9]+))?$")


def lean_number(spelling: str) -> str:
    """The spelling of a JSON number in the form of Lean `Json.compress` (a zero is `0`)."""
    sign, whole, fraction, exponent_sign, exponent = NUMBER_GRAMMAR.match(spelling).groups()
    fraction = fraction or ""
    digits = (whole + fraction).lstrip("0") or "0"
    places = len(fraction)
    if exponent is not None:
        count = int(exponent)
        if count > EXPONENT_LIMIT:
            raise ValueError(f"the exponent of {spelling} is beyond the limit of the JSON reader")
        if exponent_sign == "-":
            places += count
        elif count > places:
            if digits != "0":
                digits += "0" * (count - places)
            places = 0
        else:
            places -= count
    mantissa = ("-" if sign and digits != "0" else "") + digits
    if places == 0:
        return mantissa
    negative = "-" if mantissa.startswith("-") else ""
    magnitude = mantissa.lstrip("-")
    shift = min(9 + len(magnitude) - places, 0)
    width = places - abs(shift)
    padded = magnitude.zfill(width)
    left = padded[:len(padded) - width] or "0"
    remainder = padded[len(padded) - width:]
    if shift == 0 and not remainder.strip("0"):
        return negative + left
    return negative + left + "." + remainder.rstrip("0") + (f"e{shift}" if shift else "")


def lean_string(text: str) -> str:
    """The string in the form of Lean `Json.compress`: only `"`, `\\`, newline, carriage return, and the
    characters below U+0020 are escaped."""
    parts = ['"']
    for character in text:
        if character == '"':
            parts.append('\\"')
        elif character == "\\":
            parts.append("\\\\")
        elif character == "\n":
            parts.append("\\n")
        elif character == "\r":
            parts.append("\\r")
        elif ord(character) < 0x20:
            parts.append(f"\\u{ord(character):04x}")
        else:
            parts.append(character)
    parts.append('"')
    return "".join(parts)


def number_spelling(value) -> str | None:
    if isinstance(value, RawNumber):
        return value.spelling
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return json.dumps(value, allow_nan=False)
    return None


def canonical(value) -> str:
    """The digest text of a JSON value, the form of Lean `canonicalJson`: the keys sorted, no space, the
    strings and numbers in the form of Lean `Json.compress`."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return lean_string(value)
    if isinstance(value, dict):
        return "{" + ",".join(lean_string(key) + ":" + canonical(value[key]) for key in sorted(value)) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(canonical(item) for item in value) + "]"
    return lean_number(number_spelling(value))


def sha(value) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


EXECUTION_FAILURES = ("argumentCoverage", "invalidOutcome", "invalidPlan", "missingArgument", "missingProvider",
                      "missingValue", "network", "networkTerminal", "provider", "providerCoverage", "providerEffect",
                      "resource", "value")


def _member(value, key):
    return value.get(key) if isinstance(value, dict) else None


def _rows(value, keys):
    return [{key: _member(item, key) for key in keys} for item in value] if isinstance(value, list) else []


def goal_observations(composition):
    """The goal observations of a composition, or None without a composition."""
    if composition is None:
        return None
    goal = _member(_member(composition, "problem"), "goal")
    return {"outputs": _rows(_member(goal, "outputs"), ("id", "contract")),
            "failures": _rows(_member(goal, "failures"), ("id", "contract", "final_resources")),
            "final_resources": _member(goal, "final_resources"),
            "effects": ["network_instruction", "pending"], "residuals": "residual_set",
            "execution_failures": list(EXECUTION_FAILURES), "provenance": "certificate_basis"}


def observations_digest(composition):
    observations = goal_observations(composition)
    return None if observations is None else sha(observations)


def expected_document(basis, composition):
    """The expected document of a basis and the goal observations of a composition."""
    return {"basis": basis, "observations": goal_observations(composition)}


def compact(value) -> str:
    """The compact JSON text of a value that may hold raw numbers."""
    if isinstance(value, RawNumber):
        return value.spelling
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(key, ensure_ascii=False) + ":" + compact(item)
                              for key, item in value.items()) + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(compact(item) for item in value) + "]"
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def path_text(path: tuple, generic: bool) -> str:
    text = "$"
    for step in path:
        if isinstance(step, int):
            text += "[*]" if generic else f"[{step}]"
        else:
            text += f".{step}"
    return text


def walk(value, path: tuple = ()) -> Iterator[tuple[tuple, object]]:
    yield path, value
    if isinstance(value, dict):
        for name, item in value.items():
            yield from walk(item, path + (name,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from walk(item, path + (index,))


def get_node(root, path: tuple):
    node = root
    for step in path:
        node = node[step]
    return node


def edited(node, path: tuple, edit: Edit):
    if not path:
        return copy.deepcopy(edit.value)
    step = path[0]
    changed = dict(node) if isinstance(node, dict) else list(node)
    if len(path) == 1:
        if edit.action == "delete":
            del changed[step]
        else:
            changed[step] = copy.deepcopy(edit.value)
    else:
        changed[step] = edited(node[step], path[1:], edit)
    return changed


def apply_edits(exchange, edits: tuple[Edit, ...]):
    result = exchange
    for edit in edits:
        result = edited(result, edit.path, edit)
    return result


def single_mutations(path: tuple, value, parent) -> Iterator[Mutation]:
    shape = path_text(path, True)
    position = path_text(path, False)
    for name, replacement in VALUE_EDITS:
        if canonical(replacement) != canonical(value):
            yield Mutation("single", shape, position, name, (Edit(path, "set", replacement),))
    if isinstance(value, dict):
        yield Mutation("single", shape, position, "extra-key", (Edit(path + ("extra",), "set", 1),))
    if isinstance(parent, dict):
        yield Mutation("single", shape, position, "delete-field", (Edit(path, "delete"),))


def natural_mutations(path: tuple, value) -> Iterator[Mutation]:
    if isinstance(value, str) and NATURAL.match(value):
        shape = path_text(path, True)
        for replacement in NATURAL_VALUES:
            yield Mutation("natural", shape, path_text(path, False), f"natural={replacement}",
                           (Edit(path, "set", replacement),))


def extra_name_mutations(path: tuple, value, parent) -> Iterator[Mutation]:
    if not isinstance(value, dict):
        return
    names = list(parent) if isinstance(parent, dict) else []
    names += [name for name in WIRE_NAMES if name not in names]
    for name in names:
        if name not in value:
            yield Mutation("extra-name", path_text(path, True), path_text(path, False),
                           f"extra-key-named-{name}", (Edit(path + (name,), "set", 1),))


def is_json_value(value) -> bool:
    if not isinstance(value, dict) or value.get("tag") not in JSON_VALUE_TAGS:
        return False
    if value["tag"] == "Null":
        return list(value) == ["tag"]
    if value["tag"] == "Array":
        return list(value) == ["tag", "items"] and isinstance(value["items"], list)
    if value["tag"] == "Decimal":
        return list(value) == ["tag", "text"]
    return list(value) == ["tag", "value"] and not isinstance(value["value"], (dict, list))


def decimal_text_mutations(path: tuple, value) -> Iterator[Mutation]:
    if is_json_value(value):
        shape = path_text(path, True)
        for text in DECIMAL_TEXTS:
            yield Mutation("decimal-text", shape, path_text(path, False), f"decimal-text={text[:24]!r}/{len(text)}",
                           (Edit(path, "set", {"tag": "Decimal", "text": text}),))


def canonical_mutations(path: tuple, value, first_in_region: bool) -> Iterator[Mutation]:
    if not isinstance(value, str):
        return
    shape = path_text(path, True)
    position = path_text(path, False)
    strings = CONTROL_STRINGS + OTHER_STRINGS if first_in_region else REDUCED_STRINGS
    numbers = NUMBER_SPELLINGS if first_in_region else REDUCED_NUMBERS
    for text in strings:
        if text != value:
            yield Mutation("canonical", shape, position, f"canonical-string={text!r}", (Edit(path, "set", text),))
    for spelling in numbers:
        yield Mutation("canonical", shape, position, f"canonical-number={spelling}",
                       (Edit(path, "set", RawNumber(spelling)),))


def pair_mutations(path: tuple, value) -> Iterator[Mutation]:
    if not isinstance(value, dict):
        return
    names = list(value)
    shape = path_text(path, True)
    position = path_text(path, False)
    for index, first in enumerate(names):
        for second in names[index + 1:]:
            for (first_name, first_value), (second_name, second_value) in PAIR_COMBINATIONS:
                edits = tuple(
                    Edit(path + (name,), "delete") if kind == "delete-field" else Edit(path + (name,), "set", new)
                    for name, kind, new in ((first, first_name, first_value), (second, second_name, second_value)))
                yield Mutation("pair", shape, position, f"{first}={first_name}+{second}={second_name}", edits)
        for kind, new in EXTRA_PAIR_EDITS:
            yield Mutation("pair", shape, position, f"{first}={kind}+extra-key",
                           (Edit(path + (first,), "set", new), Edit(path + ("extra",), "set", 1)))


def mutations_of(exchange) -> Iterator[Mutation]:
    containers: dict[tuple, object] = {}
    tag_sequences: dict[tuple, tuple[str, ...]] = {}
    regions_seen: set[tuple] = set()
    for path, value in walk(exchange):
        parent = containers.get(path[:-1])
        tags = tag_sequences.get(path[:-1], ())
        if isinstance(value, dict) and isinstance(value.get("tag"), str):
            tags = tags + (value["tag"],)
        tag_sequences[path] = tags
        if isinstance(value, (dict, list)):
            containers[path] = value
        for generated in (single_mutations(path, value, parent), natural_mutations(path, value),
                          extra_name_mutations(path, value, parent), pair_mutations(path, value),
                          decimal_text_mutations(path, value)):
            for mutation in generated:
                yield dataclasses.replace(mutation, tags=tags)
        region = next((region for region in DIGEST_REGIONS if path[:len(region)] == region), None)
        if region is not None and isinstance(value, str):
            yield from canonical_mutations(path, value, region not in regions_seen)
            regions_seen.add(region)


def representatives(exchange, seen: set[tuple]) -> list[Mutation]:
    chosen: list[Mutation] = []
    for mutation in mutations_of(exchange):
        key = (mutation.family, mutation.shape, mutation.tags, mutation.description)
        if key in seen:
            continue
        seen.add(key)
        chosen.append(mutation)
    return chosen


def library_evidence(library) -> dict[str, object]:
    definitions = []
    outcome_origins = []
    for definition in sorted(library["definitions"], key=lambda row: row["id"]):
        projected = copy.deepcopy(definition)
        shape = projected["shape"]
        if shape["tag"] == "Operation":
            for outcome in sorted(shape["value"]["outcomes"], key=lambda row: row["id"]):
                outcome_origins.append({"definition": definition["id"], "outcome": outcome["id"],
                                        "cause": copy.deepcopy(outcome["cause"])})
        definitions.append(projected)
    for projected in definitions:
        if projected["shape"]["tag"] == "Operation":
            for outcome in projected["shape"]["value"]["outcomes"]:
                outcome["cause"] = {"tag": outcome["cause"]["tag"]}
    graph = {"profile": library["profile"], "nodes": sorted(library["nodes"], key=lambda row: row["id"]),
             "definitions": definitions}
    provenance_rows = []
    for binding in sorted(library["provenance"], key=lambda row: canonical(row["target"])):
        projected = copy.deepcopy(binding)
        projected["origins"] = sorted(projected["origins"], key=canonical)
        provenance_rows.append(projected)
    provenance = {"sources": sorted(library["sources"], key=lambda row: (
        row["repository"], row["revision"], row["path"], row["content_digest"])),
                  "provenance": provenance_rows, "outcome_origins": outcome_origins}
    groups = []
    for group in sorted(library["groups"], key=lambda row: row["id"]):
        projected = copy.deepcopy(group)
        projected["members"] = sorted(projected["members"])
        groups.append(projected)
    metadata = {"groups": groups, "annotations": sorted(library["annotations"], key=lambda row: (
        canonical(row["target"]), row["key"], canonical(row["value"])))}
    return {"graph_sha256": sha(graph), "provenance_sha256": sha(provenance), "metadata_sha256": sha(metadata)}


def derived_digests(exchange) -> dict[str, str | None]:
    digests = library_evidence(exchange["signatures"])
    digests["entrypoints_sha256"] = sha(sorted(exchange["entrypoints"], key=lambda row: row["identity"]))
    return digests


def replace_strings(value, mapping: dict[str, str]):
    if isinstance(value, str):
        return mapping.get(value, value)
    if isinstance(value, dict):
        return {name: replace_strings(item, mapping) for name, item in value.items()}
    if isinstance(value, list):
        return [replace_strings(item, mapping) for item in value]
    return value


def recomputed(base_exchange, mutated):
    """Returns the edited exchange with the declared digests derived again, or None when the edited
    exchange does not allow the derivation or the derivation changes nothing."""
    try:
        declared = base_exchange["basis"]
        digests = derived_digests(mutated)
        mapping = {declared[name]: digests[name] for name in DIGEST_FIELDS if declared[name] != digests[name]}
        result = dict(mutated)
        composition = result["composition"]
        if composition is not None and mapping:
            composition = replace_strings(composition, mapping)
            result["composition"] = composition
        result["basis"] = dict(mutated["basis"])
        for name in DIGEST_FIELDS:
            result["basis"][name] = digests[name]
        result["basis"]["problem_sha256"] = None if composition is None else sha(composition)
        result["basis"]["observations_sha256"] = observations_digest(composition)
    except Exception:
        return None
    return None if canonical(result) == canonical(mutated) else result


def derived_expected(expected_basis, variant):
    """The expected basis that agrees with the digests declared by a recomputed exchange."""
    expected = dict(expected_basis)
    for name in DIGEST_FIELDS + ("problem_sha256", "observations_sha256"):
        expected[name] = variant["basis"][name]
    return expected


def check_base(name: str, exchange) -> None:
    declared = exchange["basis"]
    digests = derived_digests(exchange)
    for field in DIGEST_FIELDS:
        if declared[field] != digests[field]:
            raise RuntimeError(f"the {field} derivation does not match the base {name}")
    composition = exchange["composition"]
    expected = None if composition is None else sha(composition)
    if declared["problem_sha256"] != expected:
        raise RuntimeError(f"the problem_sha256 derivation does not match the base {name}")
    if declared["observations_sha256"] != observations_digest(composition):
        raise RuntimeError(f"the observations_sha256 derivation does not match the base {name}")


def exhaustive_inputs(name: str, exchange, expected_basis, seen: set[tuple]) -> Iterator[ExhaustiveInput]:
    check_base(name, exchange)
    for mutation in representatives(exchange, seen):
        mutated = apply_edits(exchange, mutation.edits)
        touches_basis = any(edit.path[:1] == ("basis",) for edit in mutation.edits)
        again = None if touches_basis else recomputed(exchange, mutated)
        variants = []
        if again is None or mutation.family in STALE_FAMILIES:
            variants.append((False, mutated))
        if again is not None:
            variants.append((True, again))
        for flag, variant in variants:
            expected = derived_expected(expected_basis, variant) if flag else expected_basis
            observed = variant if flag else exchange
            request = compact({"exchange": compact(variant),
                               "expected_basis": expected_document(expected, observed["composition"])})
            yield ExhaustiveInput(name, mutation, flag, request)
