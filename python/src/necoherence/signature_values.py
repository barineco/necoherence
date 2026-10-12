# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Semantic values and runtime operations for checked signature libraries."""
from __future__ import annotations

import base64
import binascii
import json
import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from enum import EnumMeta
from typing import Callable, Generic, Protocol, TypeAlias, TypeVar
from . import network_effect as ne


@dataclass(frozen=True, slots=True)
class DecimalLiteral:
    spelling: str

    def __post_init__(self):
        try:
            value = Decimal(self.spelling)
        except InvalidOperation as error:
            raise ValueError("invalid decimal literal") from error
        if not value.is_finite():
            raise ValueError("invalid decimal literal")

    def __str__(self):
        return self.spelling


JsonValue: TypeAlias = None | bool | int | str | Decimal | DecimalLiteral | list["JsonValue"] | tuple["JsonValue", ...] | dict[str, "JsonValue"]


@dataclass(frozen=True, slots=True)
class Wrapper:
    name: str
    key: str
    payload: object


@dataclass(frozen=True, slots=True)
class SealedForm:
    tag: str
    fields: tuple[object, ...]
    extras: object


@dataclass(frozen=True, slots=True)
class TagModel:
    key: str
    format: str | None
    sealed: tuple[SealedForm, ...]


@dataclass(frozen=True, slots=True)
class Absent:
    pass


ABSENT = Absent()


@dataclass(frozen=True, slots=True)
class Present:
    value: JsonValue


@dataclass(frozen=True, slots=True)
class Unit:
    pass


UNIT = Unit()


class Uninhabited:
    def __new__(cls, *args, **kwargs):
        raise TypeError("uninhabited type")


class ValidatedEnumMeta(EnumMeta):
    def __call__(cls, value, *args, **kwargs):
        if isinstance(value, cls):
            return value
        cls.__value_context__.validate(cls.__type_reference__, value)
        return super().__call__(value, *args, **kwargs)


class MeaningFailure(ValueError):
    def __init__(self, reference, predicate, location=()):
        self.type_ref = reference
        self.predicate = predicate
        self.location = tuple(location)
        super().__init__(f"{predicate} at {reference}")


class ValueFailure(ValueError):
    def __init__(self, reference, path, condition, observed=None, trace=()):
        self.type_ref = reference
        self.definition_ref = None
        self.origin = None
        self.value_path = tuple(path)
        self.condition = condition
        self.observed = observed
        self.reference_trace = tuple(trace)
        super().__init__(f"{reference} {self.value_path}: {condition}")


class WireFailure(ValueError):
    def __init__(self, kind: str, path: str = "$", observed=None):
        self.kind = kind
        self.path = path
        self.observed = observed
        super().__init__(f"{path}: {kind}" + ("" if observed is None else f": {observed}"))


def sum_tag(value):
    return value["tag"]


def payload(value):
    return value.get("value", value.get("fields"))


def variant(name, value=ABSENT, *, fields=None):
    if fields is not None:
        return {"tag": name, "fields": fields}
    return {"tag": name} if value is ABSENT else {"tag": name, "value": value}


def ref_key(reference):
    if isinstance(reference, str):
        return reference
    if isinstance(reference, dict):
        return json.dumps(reference, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return reference


def integer(value):
    if type(value) is int:
        return value
    if isinstance(value, DecimalLiteral):
        value = value.spelling
    if isinstance(value, Decimal):
        if value != value.to_integral_value():
            raise ValueError("integer required")
        return int(value)
    if type(value) is not str or re.fullmatch(r"0|-?[1-9][0-9]*", value) is None:
        raise ValueError("canonical integer required")
    return int(value)


def integer_text(value):
    return str(integer(value))


def exact_decode(value):
    kind = sum_tag(value)
    if kind == "Null": return None
    if kind == "Bool": return payload(value)
    if kind == "Integer": return integer(payload(value))
    if kind == "Decimal": return DecimalLiteral(value["text"])
    if kind == "String": return payload(value)
    if kind == "Array": return [exact_decode(item) for item in value["items"]]
    if kind == "Object": return {item["key"]: exact_decode(item["value"]) for item in value["members"]}
    raise WireFailure("UnknownTag", observed=kind)


def exact_encode(value):
    if value is None: return variant("Null")
    if type(value) is bool: return variant("Bool", value)
    if type(value) is int: return variant("Integer", str(value))
    if isinstance(value, (Decimal, DecimalLiteral)):
        return {"tag": "Decimal", "text": str(value)}
    if type(value) is str: return variant("String", value)
    if isinstance(value, (list, tuple)): return {"tag": "Array", "items": [exact_encode(item) for item in value]}
    if isinstance(value, dict): return {"tag": "Object", "members": [{"key": key, "value": exact_encode(item)} for key, item in value.items()]}
    raise TypeError("exact JSON value required")


def decode_wire_json(text: str):
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                raise WireFailure("DuplicateField", observed=key)
            result[key] = value
        return result
    try:
        return json.loads(text, object_pairs_hook=pairs, parse_int=lambda text: integer(text), parse_float=DecimalLiteral,
                          parse_constant=lambda text: (_ for _ in ()).throw(ValueError(text)))
    except WireFailure:
        raise
    except (ValueError, json.JSONDecodeError) as error:
        raise WireFailure("Syntax", observed=str(error)) from None


def encode_wire_json(value):
    if isinstance(value, DecimalLiteral): return value.spelling
    if isinstance(value, Decimal): return str(value)
    if value is None: return "null"
    if type(value) is bool: return "true" if value else "false"
    if type(value) is int: return str(value)
    if type(value) is str: return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (list, tuple)): return "[" + ",".join(encode_wire_json(item) for item in value) + "]"
    if isinstance(value, dict): return "{" + ",".join(json.dumps(key, ensure_ascii=False) + ":" + encode_wire_json(item) for key, item in value.items()) + "}"
    raise TypeError("exact JSON value required")


def wrapEncode(profile, wrapper_name, value):
    wrapper = _named(profile.get("wrappers", ()), wrapper_name)
    if wrapper is None:
        raise ValueFailure(wrapper_name, (), "InvalidWrapper", value)
    return {_field(wrapper, "key"): value}


def wrapDecode(profile, wrapper_name, value):
    wrapper = _named(profile.get("wrappers", ()), wrapper_name)
    key = None if wrapper is None else _field(wrapper, "key")
    if wrapper is None or type(value) is not dict or list(value) != [key] or type(value[key]) is not str:
        raise ValueFailure(wrapper_name, (), "InvalidWrapper", value)
    return value[key]


def withMember(key, text, value):
    if type(value) is not dict:
        raise ValueFailure(key, (), "WrongValueKind:object", value)
    return {key: text, **{name: item for name, item in value.items() if name != key}}


def _field(value, name, default=None):
    return value.get(name, default) if isinstance(value, dict) else getattr(value, name, default)


def _named(values, name):
    return next((value for value in values if _field(value, "name") == name), None)


def _unit(value):
    return sum_tag(value) if isinstance(value, dict) else value


def _canonical_decimal_string(text):
    return type(text) is str and re.fullmatch(r"0|-?[1-9][0-9]*", text) is not None


def _integer_value(profile, spec, value):
    name = spec.get("domain") or profile.get("default_integer_domain")
    binding = _named(profile.get("integer_domains", ()), name)
    if binding is None:
        return None, "IntegerDomain"
    forms = {_unit(form) for form in binding.get("forms", ())}
    try:
        if type(value) is int and "Number" in forms:
            result = value
        elif isinstance(value, (float, DecimalLiteral, Decimal)) and "IntegralDecimal" in forms:
            parsed_decimal = Decimal(str(value))
            if not parsed_decimal.is_finite() or parsed_decimal != parsed_decimal.to_integral_value():
                return None, "WrongValueKind:integer"
            result = int(parsed_decimal)
        elif _canonical_decimal_string(value) and "DecimalString" in forms:
            result = int(value)
        else:
            return None, "WrongValueKind:integer"
    except (ValueError, InvalidOperation):
        return None, "WrongValueKind:integer"
    domain = binding.get("range", {"tag": "Unbounded"})
    if sum_tag(domain) == "Inclusive":
        fields = payload(domain)
        if result < integer(fields["minimum"]) or result > integer(fields["maximum"]):
            return None, "IntegerDomain"
    return result, None


def _length(profile, unit, text):
    name = _unit(unit)
    if name == "Utf8Bytes": return len(text.encode("utf-8"))
    if name == "UnicodeScalars": return len(text)
    if name == "Graphemes":
        if profile.get("grapheme_rules") is None: return None
        return sum(not (0x300 <= ord(char) <= 0x36F) for char in text)
    return None


def _format(profile, use, text):
    if use is None: return True
    kind = sum_tag(use)
    if kind == "Inline": return recognize_format(payload(use), text)
    binding = _named(profile.get("format_bindings", ()), payload(use))
    return binding is not None and recognize_format(binding["rule"], text)


def _unicode_scalar_text(text):
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def recognize_format(rule, text):
    if type(text) is not str: return False
    kind, spec = sum_tag(rule), payload(rule)
    if kind == "Text": return True
    if kind == "Not": return not recognize_format(spec, text)
    if kind == "Literal": return text == spec
    if kind == "Choice": return any(recognize_format(item, text) for item in spec)
    if kind == "Optional": return text == "" or recognize_format(spec, text)
    if kind == "Sequence":
        states = {0}
        for item in spec:
            following = set()
            for start in states:
                for end in range(start, len(text) + 1):
                    if recognize_format(item, text[start:end]): following.add(end)
            states = following
        return len(text) in states
    if kind == "Labels":
        if not spec["separator"]: return False
        parts = text.split(spec["separator"])
        if len(parts) < integer(spec["min_count"]): return False
        if spec["max_count"] is not None and len(parts) > integer(spec["max_count"]): return False
        if spec["total_max"] is not None and len(text) > integer(spec["total_max"]): return False
        return all(recognize_format(spec["rule"], part) for part in parts)
    if kind == "Bounded":
        length = len(text.encode()) if _unit(spec["unit"]) == "Utf8Bytes" else len(text)
        return length <= integer(spec["maximum"]) and recognize_format(spec["rule"], text)
    if kind == "Identifier":
        exact = spec["exact_length"]
        if exact is not None and len(text) != integer(exact): return False
        if len(text) < integer(spec["min_length"]): return False
        if spec["max_length"] is not None and len(text) > integer(spec["max_length"]): return False
        return bool(text) and text[0] in spec["first_alphabet"] and all(c in spec["rest_alphabet"] for c in text[1:]) and text not in spec["forbidden"]
    if kind == "AsciiDfa":
        state = integer(spec["initial_state"])
        for char in text:
            code = ord(char)
            transition = next((row for row in spec["transitions"] if integer(row["from_state"]) == state and integer(row["first"]) <= code <= integer(row["last"])), None)
            if transition is None: return False
            state = integer(transition["to_state"])
        return str(state) in spec["accepting_states"] or state in spec["accepting_states"]
    if kind == "AbsoluteUri": return ":" in text and (spec["max_bytes"] is None or len(text.encode()) <= integer(spec["max_bytes"]))
    if kind == "LanguageTag": return bool(re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", text)) or text in spec["grandfathered"]
    if kind == "Timestamp": return bool(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})", text))
    return False


def _bytes_text(profile, value):
    policy = profile.get("bytes_policy")
    if policy is None: return None
    wrapper = policy.get("wrapper")
    text = wrapDecode(profile, wrapper, value) if wrapper is not None else value
    if type(text) is not str: return None
    alphabet = _unit(policy.get("alphabet", {"tag": "Standard"}))
    allowed = {"Standard": r"[A-Za-z0-9+/]*={0,2}", "UrlSafe": r"[A-Za-z0-9_-]*={0,2}", "Either": r"[A-Za-z0-9+/_-]*={0,2}"}[alphabet]
    if re.fullmatch(allowed, text) is None: return None
    try:
        normalized = text.replace("-", "+").replace("_", "/")
        return base64.b64decode(normalized + "=" * ((-len(normalized)) % 4), validate=True)
    except (binascii.Error, ValueError):
        return None


def classOf(profile, members):
    if type(members) is dict: members = list(members.items())
    values = dict(members)
    model = profile.get("tag")
    if model is not None and type(values.get(model["key"])) is str:
        form = next((form for form in model["sealed"] if form["tag"] == values[model["key"]]), None)
        if form is not None: return ("Sealed", form)
    wrapper = next((item for item in profile.get("wrappers", ()) if item["key"] in values), None)
    return ("Wrapper", wrapper) if wrapper is not None else ("Ordinary", None)


def selectBranch(graph, reference, value):
    context = graph if isinstance(graph, ValueContext) else ValueContext(graph)
    shape = context.shape(reference)
    if sum_tag(shape) != "TaggedUnion":
        raise ValueFailure(reference, (), "NoBranchSelected", value)
    for index, branch in enumerate(payload(shape)["branches"]):
        selector = branch["selector"]
        kind = sum_tag(selector)
        if kind == "InternalTag":
            model = context.profile.get("tag")
            if model is not None and type(value) is dict and value.get(model["key"]) == branch["wire_tag"]: return index
        elif kind == "MemberShape" and type(value) is dict:
            accepted = True
            for test in payload(selector):
                check = test["test"]
                if sum_tag(check) == "Absent": accepted &= test["key"] not in value
                else:
                    binding = _named(context.profile.get("format_bindings", ()), payload(check))
                    accepted &= test["key"] in value and binding is not None and recognize_format(binding["rule"], value[test["key"]])
            if accepted: return index
        elif kind == "Kind":
            expected = sum_tag(payload(selector))
            actual = "Null" if value is None else "Boolean" if type(value) is bool else "Number" if isinstance(value, (int, DecimalLiteral, Decimal)) else "String" if type(value) is str else "Array" if isinstance(value, list) else "Object" if isinstance(value, dict) else "Unknown"
            if actual == expected: return index
        elif kind == "Otherwise": return index
    raise ValueFailure(reference, (), "NoBranchSelected", value)


class ValueContext:
    def __init__(self, graph):
        self.graph = graph
        self.profile = graph["profile"]
        self.nodes = {}
        self.references = {}
        for node in graph.get("nodes", ()):
            reference = node.get("reference", node.get("ref", node.get("id")))
            self.nodes[ref_key(reference)] = node
            if "id" in node:
                self.references[ref_key(node["id"])] = reference
        self._registered = {}

    def reference(self, reference):
        return self.references.get(ref_key(reference), reference)

    def grapheme_boundaries(self, text):
        if not text:
            return ()
        rules = self.profile.get("grapheme_rules")
        boundaries = [0]
        for index, character in enumerate(text):
            codepoint = ord(character)
            extending = rules is not None and any(
                integer(row["first"]) <= codepoint <= integer(row["last"]) and sum_tag(row["property"]) == "Extend"
                for row in rules.get("properties", ())
            )
            if index and not extending:
                boundaries.append(index)
        if text:
            boundaries.append(len(text))
        return tuple(boundaries)

    def grapheme_count(self, text):
        boundaries = self.grapheme_boundaries(text)
        return max(0, len(boundaries) - 1)

    def register(self, reference, native):
        self._registered[ref_key(reference)] = native

    def shape(self, reference):
        reference = self.reference(reference)
        node = self.nodes.get(ref_key(reference))
        if node is None: raise ValueFailure(reference, (), "UnresolvedType")
        return node["shape"]

    def resolved(self, reference):
        seen = set()
        current = reference
        while sum_tag(self.shape(current)) == "Alias":
            if ref_key(current) in seen: raise ValueFailure(reference, (), "ReferenceCycle")
            seen.add(ref_key(current)); current = payload(self.shape(current))["target"] if isinstance(payload(self.shape(current)), dict) else payload(self.shape(current))
        return current, self.shape(current)

    def check_meaning(self, reference):
        pending = [reference]
        seen = set()
        while pending:
            current = pending.pop(0)
            current = self.reference(current)
            key = ref_key(current)
            if key in seen:
                continue
            seen.add(key)
            node = self.nodes.get(key)
            if node is None:
                continue
            kind, spec = sum_tag(node["shape"]), payload(node["shape"])
            failure = None
            if kind == "String":
                if any(sum_tag(bound["unit"]) == "Graphemes" for bound in spec["lengths"]) and self.profile.get("grapheme_rules") is None:
                    failure = "MO02"
                elif spec["format"] is not None and sum_tag(spec["format"]) == "Named" and _named(self.profile.get("format_bindings", ()), payload(spec["format"])) is None:
                    failure = "MO01"
                elif spec["wrapper"] is not None:
                    wrapper = _named(self.profile.get("wrappers", ()), spec["wrapper"])
                    if wrapper is None:
                        failure = "MO05"
                    elif sum_tag(wrapper["payload"]) != "Text":
                        failure = "MO06"
            elif kind == "Integer":
                binding = _named(self.profile.get("integer_domains", ()), spec["domain"] or self.profile.get("default_integer_domain"))
                if binding is None:
                    failure = "MO04"
                elif sum_tag(binding["range"]) == "Inclusive":
                    domain = payload(binding["range"])
                    if (spec["minimum"] is not None and integer(spec["minimum"]) < integer(domain["minimum"])) or (spec["maximum"] is not None and integer(spec["maximum"]) > integer(domain["maximum"])):
                        failure = "MO09"
            elif kind == "Decimal" and not self.profile.get("numbers", {}).get("decimals", False):
                failure = "MO08"
            elif kind in ("Bytes", "RawBody") and self.profile.get("bytes_policy") is None:
                failure = "MO03"
            elif kind == "Sealed":
                model = self.profile.get("tag")
                if model is None or not any(form["tag"] == spec["tag"] for form in model["sealed"]):
                    failure = "MO07"
            elif kind == "TaggedUnion" and any(sum_tag(branch["selector"]) == "InternalTag" for branch in spec["branches"]) and self.profile.get("tag") is None:
                failure = "MO11"
            elif kind == "Opaque":
                failure = "MO10"
            if failure is not None:
                raise MeaningFailure(current, failure)
            if kind == "Product":
                pending.extend(field["slot"]["type_id"] for field in spec["fields"])
                if sum_tag(spec["extras"]) == "Allow":
                    pending.append(payload(spec["extras"])["value"]["type_id"])
            elif kind == "Array":
                pending.append(spec["item"]["type_id"])
            elif kind == "Alias":
                pending.append(spec["target"])
            elif kind == "TaggedUnion":
                pending.extend(branch["target"] for branch in spec["branches"])

    def validate_slot(self, contract, value, path=()):
        if isinstance(value, Absent):
            if contract["required"]: raise ValueFailure(contract["type_ref"], path, "MissingRequired", "absent")
        elif value is None:
            if not contract["nullable"]: raise ValueFailure(contract["type_ref"], path, "NullNotAllowed", None)
        else: self.validate(contract["type_ref"], value, path)
        return value

    def validate_element(self, contract, value, path, active, evaluation_path):
        if value is None and contract["nullable"]:
            return value
        return self.validate(contract["type_id"], value, path, active, evaluation_path)

    def validate(self, reference, value, path=(), active=(), evaluation_path=None):
        reference = self.reference(reference)
        if evaluation_path is None:
            evaluation_path = path
        if not active:
            self.check_meaning(reference)
        key = ref_key(reference)
        trace = tuple(item for item, _ in active)
        if any(ref_key(item) == key and at == evaluation_path for item, at in active): raise ValueFailure(reference, path, "ReferenceCycle", value, trace)
        shape = self.shape(reference)
        kind, spec = sum_tag(shape), payload(shape)
        next_active = (*active, (reference, evaluation_path))
        def reject(condition, observed=value, at=path): raise ValueFailure(reference, at, condition, observed, trace)
        if kind == "Alias":
            return self.validate(spec["target"], value, path, next_active, evaluation_path)
        if kind == "Never": reject("InvalidDataModel")
        if kind == "Opaque": reject("Unresolved:opaque")
        if kind == "Unit":
            if value is not None: reject("WrongValueKind:null")
        elif kind == "Unknown":
            if type(value) is dict: self._validate_tag_member(reference, value, path, trace)
            if sum_tag(spec) == "OrdinaryObject" and (type(value) is not dict or classOf(self.profile, value)[0] != "Ordinary"): reject("WrongValueKind:ordinary object")
        elif kind == "Boolean":
            if type(value) is not bool: reject("WrongValueKind:boolean")
            if spec["const_value"] is not None and value != spec["const_value"]: reject("ConstMismatch")
        elif kind == "Integer":
            parsed, failure = _integer_value(self.profile, spec, value)
            if failure: reject(failure)
            if spec["const_value"] is not None and parsed != integer(spec["const_value"]): reject("ConstMismatch")
            if spec["enum_values"] is not None and parsed not in map(integer, spec["enum_values"]): reject("EnumMismatch")
            if spec["minimum"] is not None and parsed < integer(spec["minimum"]): reject("BelowMinimum")
            if spec["maximum"] is not None and parsed > integer(spec["maximum"]): reject("AboveMaximum")
        elif kind == "Decimal":
            if not isinstance(value, (float, DecimalLiteral, Decimal)): reject("WrongValueKind:decimal")
            dec = Decimal(str(value))
            if not dec.is_finite(): reject("InvalidDataModel")
            scale = max(0, -dec.as_tuple().exponent); mantissa = int(dec.scaleb(scale))
            for name, below in (("minimum", True), ("maximum", False)):
                bound = spec[name]
                if bound is not None:
                    target = Decimal(integer(bound["mantissa"])).scaleb(-integer(bound["scale"]))
                    if (below and (dec < target or bound["exclusive"] and dec == target)) or (not below and (dec > target or bound["exclusive"] and dec == target)): reject("BelowMinimum" if below else "AboveMaximum")
        elif kind == "String":
            text = wrapDecode(self.profile, spec["wrapper"], value) if spec["wrapper"] is not None else value
            if type(text) is not str: reject("WrongValueKind:string")
            if spec["const_value"] is not None and text != spec["const_value"]: reject("ConstMismatch")
            if spec["enum_values"] is not None and text not in spec["enum_values"]: reject("EnumMismatch")
            for bound in spec["lengths"]:
                length = _length(self.profile, bound["unit"], text)
                if length is None or bound["minimum"] is not None and length < integer(bound["minimum"]) or bound["maximum"] is not None and length > integer(bound["maximum"]): reject("StringLength")
            if not _format(self.profile, spec["format"], text):
                name = payload(spec["format"]) if sum_tag(spec["format"]) == "Named" else "inline"
                reject(f"Format:{name}")
        elif kind in ("Bytes", "RawBody"):
            decoded = _bytes_text(self.profile, value)
            if decoded is None: reject("InvalidBytes")
            if kind == "Bytes":
                if spec["minimum"] is not None and len(decoded) < integer(spec["minimum"]): reject("BytesLength")
                if spec["maximum"] is not None and len(decoded) > integer(spec["maximum"]): reject("BytesLength")
        elif kind == "Array":
            if type(value) is not list: reject("WrongValueKind:array")
            if spec["min_length"] is not None and len(value) < integer(spec["min_length"]): reject("ArrayLength")
            if spec["max_length"] is not None and len(value) > integer(spec["max_length"]): reject("ArrayLength")
            item = spec["item"]
            for index, child in enumerate(value):
                self.validate_element(item, child, (*path, index), next_active, (*evaluation_path, index))
        elif kind == "Product":
            if type(value) is not dict: reject("WrongValueKind:object")
            self._validate_tag_member(reference, value, path, trace)
            fields = {field["wire_name"]: field for field in spec["fields"]}
            for name, field in fields.items():
                if name not in value:
                    if field["slot"]["required"]:
                        raise ValueFailure(self.reference(field["slot"]["type_id"]), (*path, name), "MissingRequired", "absent", trace)
                elif value[name] is None:
                    if not field["slot"]["nullable"]:
                        raise ValueFailure(self.reference(field["slot"]["type_id"]), (*path, name), "NullNotAllowed", None, trace)
                else: self.validate(field["slot"]["type_id"], value[name], (*path, name), next_active, (*evaluation_path, name))
            extras = spec["extras"]
            for name, child in value.items():
                if name in fields:
                    continue
                if self.profile.get("tag") is not None and name == self.profile["tag"]["key"]:
                    continue
                if sum_tag(extras) == "Reject": reject(f"UnexpectedField:{name}", child, (*path, name))
                details = payload(extras)
                if details["key_format"] is not None and not _format(self.profile, details["key_format"], name): reject(f"KeyFormat:{name}", name, (*path, name))
                self.validate_element(details["value"], child, (*path, name), next_active, (*evaluation_path, name))
        elif kind == "Sealed":
            if type(value) is dict: self._validate_tag_member(reference, value, path, trace)
            if type(value) is not dict or classOf(self.profile, value)[0] != "Sealed":
                reject("WrongValueKind:sealed object")
            model = self.profile.get("tag")
            form = next(item for item in model["sealed"] if item["tag"] == spec["tag"])
            known = {model["key"]}
            refinements = {row["key"]: row["leaf"] for row in spec["refinements"]}
            for field in form["fields"]:
                known.add(field["key"]); leaf = refinements.get(field["key"], field["leaf"])
                if field["key"] not in value:
                    if field["required"]: reject("MissingRequired", "absent", (*path, field["key"]))
                else: self._validate_leaf(reference, leaf, value[field["key"]], (*path, field["key"]))
            if sum_tag(form["extras"]) == "Reject":
                for name in value:
                    if name not in known: reject(f"UnexpectedField:{name}", value[name], (*path, name))
        elif kind == "TaggedUnion":
            if type(value) is dict: self._validate_tag_member(reference, value, path, trace)
            index = selectBranch(self, reference, value)
            self.validate(spec["branches"][index]["target"], value, (*path, spec["branches"][index]["wire_tag"]), next_active, evaluation_path)
        return value

    def _validate_tag_member(self, reference, value, path, active):
        model = self.profile.get("tag")
        if model is None or model["key"] not in value:
            return
        tag = value[model["key"]]
        at = (*path, model["key"])
        if type(tag) is not str:
            raise ValueFailure(reference, at, "InvalidTag", tag, active)
        if not _unicode_scalar_text(tag):
            raise ValueFailure(reference, at, "InvalidDataModel", tag, active)
        if model["format"] is not None and not _format(self.profile, variant("Named", model["format"]), tag):
            raise ValueFailure(reference, at, "InvalidTag", tag, active)

    def _validate_leaf(self, reference, leaf, value, path):
        kind, spec = sum_tag(leaf), payload(leaf)
        if kind == "String":
            text = wrapDecode(self.profile, spec["wrapper"], value) if spec["wrapper"] is not None else value
            if type(text) is not str: raise ValueFailure(reference, path, "WrongValueKind:string", value)
            if not _format(self.profile, spec["format"], text): raise ValueFailure(reference, path, "Format", value)
        else:
            parsed, failure = _integer_value(self.profile, spec, value)
            if failure: raise ValueFailure(reference, path, failure, value)
        return value

    def decode(self, reference, value):
        self.validate(reference, value)
        return value

    def encode(self, reference, value):
        self.validate(reference, value)
        return value


def slot_decode(slot):
    return ABSENT if sum_tag(slot) == "Absent" else None if sum_tag(slot) == "Null" else Present(exact_decode(slot["value"]))




def evaluate_guard(context, declaration, inspected, projected_type):
    value = inspected.value if isinstance(inspected, Present) else inspected
    kind = sum_tag(declaration["kind"])
    if kind == "Presence": return variant("Present" if not isinstance(inspected, Absent) else "Absent")
    if kind == "Variant": return variant("Variant", selectBranch(context, projected_type, value))
    return variant("Accepted")


def producer_key(producer):
    return json.dumps(producer, sort_keys=True, separators=(",", ":"))


_Input = TypeVar("_Input")
_Output = TypeVar("_Output")


@dataclass(frozen=True, slots=True)
class Ready:
    attempt: ne.AttemptInput


@dataclass(frozen=True, slots=True)
class Completed(Generic[_Output]):
    outcome: _Output


class NetworkAdapter(Protocol):
    def start(self, command: ne.SendCommand) -> ne.Started | ne.StartFailed: ...
    def observe(self, started: ne.StartedAttempt) -> ne.HostObservation: ...


@dataclass(frozen=True, slots=True)
class NetworkExecutionFailure:
    result: ne.NetworkRejected


@dataclass(frozen=True, slots=True)
class HttpPending(Generic[_Output]):
    binding: HttpBinding
    started: ne.StartedAttempt

    @property
    def state(self) -> ne.NetworkState:
        return self.binding.state

    def resume(self) -> _Output | HttpPending[_Output] | NetworkExecutionFailure | ne.NetworkLate | ne.Duplicate:
        return self.binding.observe(self.started)


class HttpBinding(Generic[_Input, _Output]):
    def __init__(
        self,
        state: ne.NetworkState,
        adapter: NetworkAdapter,
        prepare: Callable[[_Input], Ready | Completed[_Output]],
        decoder: Callable[[ne.SettledAttempt], _Output],
    ):
        self._state = state
        self.adapter = adapter
        self.prepare = prepare
        self.decoder = decoder

    @property
    def state(self) -> ne.NetworkState:
        return self._state

    def _terminal(self, result):
        self._state = result.state
        if isinstance(result, ne.NetworkRejected):
            return NetworkExecutionFailure(result)
        if isinstance(result, ne.NetworkTerminalResult):
            return self.decoder(result.settled)
        if isinstance(result, (ne.NetworkStarted, ne.NetworkPending)):
            return HttpPending(self, result.started)
        if isinstance(result, (ne.NetworkLate, ne.Duplicate)):
            return result
        raise TypeError("HTTP binding requires a start, pending, terminal, or rejected ledger result")

    def call(
        self,
        arguments: _Input,
        external_outcomes: tuple[tuple[type, str], ...],
    ) -> _Output | HttpPending[_Output] | NetworkExecutionFailure | ne.NetworkLate | ne.Duplicate:
        prepared_result = self.prepare(arguments)
        if isinstance(prepared_result, Completed):
            outcome = prepared_result.outcome
            matching = next(
                (
                    identity
                    for outcome_type, identity in external_outcomes
                    if type(outcome) is outcome_type
                ),
                None,
            )
            if matching is None:
                raise TypeError("completed preparation requires a declared external failure")
            if getattr(outcome, "outcome_id", None) != matching:
                raise TypeError("completed preparation outcome identity mismatch")
            return outcome
        if not isinstance(prepared_result, Ready):
            raise TypeError("prepare must return Ready(AttemptInput) or Completed(TypedOutcome)")
        attempt = prepared_result.attempt
        if type(attempt) is not ne.AttemptInput:
            raise TypeError("Ready requires AttemptInput")
        prepared = ne.prepare(self._state, attempt)
        self._state = prepared.state
        if isinstance(prepared, ne.NetworkRejected):
            return NetworkExecutionFailure(prepared)
        command = ne.send_command(self._state, prepared.prepared)
        self._state = command.state
        if isinstance(command, ne.NetworkRejected):
            return NetworkExecutionFailure(command)
        start = ne.observe_start(
            self._state,
            prepared.prepared,
            self.adapter.start(command.command),
        )
        self._state = start.state
        if isinstance(start, ne.NetworkStarted):
            return self.observe(start.started)
        return self._terminal(start)

    def observe(
        self,
        started: ne.StartedAttempt,
    ) -> _Output | HttpPending[_Output] | NetworkExecutionFailure | ne.NetworkLate | ne.Duplicate:
        return self._terminal(ne.observe(self._state, self.adapter.observe(started)))


@dataclass(frozen=True, slots=True)
class Pending(Generic[_Output]):
    continuation: Callable[[], object]
    state: object = None

    def resume(self):
        return self.continuation()


class ProviderContractFailure(ValueError):
    pass
