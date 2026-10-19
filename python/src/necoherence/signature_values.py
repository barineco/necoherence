# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Semantic values and runtime operations for checked signature libraries."""
from __future__ import annotations

import base64
import json
import re
from collections.abc import Mapping
from types import MappingProxyType
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from enum import EnumMeta
from typing import Callable, Generic, Protocol, TypeAlias, TypeVar
from . import network_effect as ne


@dataclass(frozen=True, slots=True)
class DecimalLiteral:
    spelling: str

    def __post_init__(self):
        if not isinstance(self.spelling, str) or re.fullmatch(
            r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?",
            self.spelling,
        ) is None:
            raise ValueError("invalid decimal literal")
        try:
            value = Decimal(self.spelling)
        except InvalidOperation as error:
            raise ValueError("invalid decimal literal") from error
        if not value.is_finite():
            raise ValueError("invalid decimal literal")

    def __str__(self):
        return self.spelling


@dataclass(frozen=True, slots=True, eq=False)
class JsonObject(Mapping):
    _members: tuple

    def __init__(self, members):
        object.__setattr__(self, "_members", tuple(members))

    def __getitem__(self, key):
        for name, value in self._members:
            if name == key:
                return value
        raise KeyError(key)

    def __iter__(self):
        return (name for name, _ in self._members)

    def __len__(self):
        return len(self._members)

    def items(self):
        return iter(self._members)


JsonValue: TypeAlias = None | bool | int | str | Decimal | DecimalLiteral | list["JsonValue"] | tuple["JsonValue", ...] | Mapping[str, "JsonValue"]


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
        self.definition_ref = {"source": reference["source"], "name": reference["definition_name"]} if isinstance(reference, Mapping) else None
        self.origin = {"source": reference["source"], "pointer": reference["pointer"]} if isinstance(reference, Mapping) else None
        self.value_path = tuple(path)
        self.condition = condition
        self.observed = observed
        self.reference_trace = tuple(trace)
        super().__init__(f"{reference} {self.value_path}: {condition}")


class UnresolvedValueFailure(ValueFailure):
    def __init__(self, obligations):
        self.obligations = tuple(_freeze_json(item) for item in obligations)
        first = self.obligations[0]
        super().__init__(first["type_ref"], first["value_path"], "Unresolved:" + first["reason"]["tag"])


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
    if isinstance(reference, Mapping):
        return json.dumps(_thaw_json(reference), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
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
    if kind == "Object": return JsonObject((item["key"], exact_decode(item["value"])) for item in value["members"])
    raise WireFailure("UnknownTag", observed=kind)


def exact_encode(value):
    if value is None: return variant("Null")
    if type(value) is bool: return variant("Bool", value)
    if type(value) is int: return variant("Integer", str(value))
    if isinstance(value, (Decimal, DecimalLiteral)):
        return {"tag": "Decimal", "text": str(value)}
    if type(value) is str: return variant("String", value)
    if isinstance(value, (list, tuple)): return {"tag": "Array", "items": [exact_encode(item) for item in value]}
    if isinstance(value, Mapping): return {"tag": "Object", "members": [{"key": key, "value": exact_encode(item)} for key, item in value.items()]}
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
    if isinstance(value, Mapping): return "{" + ",".join(json.dumps(key, ensure_ascii=False) + ":" + encode_wire_json(item) for key, item in value.items()) + "}"
    raise TypeError("exact JSON value required")


def ordered_object(value, member_order):
    order = dict.fromkeys((*member_order, *value))
    return {key: value[key] for key in order if key in value}


def wrapEncode(profile, wrapper_name, value):
    wrapper = _named(profile.get("wrappers", ()), wrapper_name)
    if wrapper is None:
        raise ValueFailure(wrapper_name, (), "InvalidWrapper", value)
    return {_field(wrapper, "key"): value}


def _wrapper_text(profile, wrapper_name, value):
    wrapper = _named(profile.get("wrappers", ()), wrapper_name)
    key = None if wrapper is None else _field(wrapper, "key")
    if wrapper is None or not isinstance(value, Mapping) or list(value) != [key] or type(value[key]) is not str:
        return None
    text = value[key]
    wrapper_payload = _field(wrapper, "payload")
    if sum_tag(wrapper_payload) == "Bytes":
        policy = profile.get("bytes_policy")
        return text if policy is not None and _base64_decode(policy, text) is not None else None
    if not _unicode_scalar_text(text):
        return None
    format_name = payload(wrapper_payload)
    if format_name is not None and not _format(profile, variant("Named", format_name), text):
        return None
    return text


def _wrapper_payload_failure(wrapper):
    wrapper_payload = _field(wrapper, "payload")
    if sum_tag(wrapper_payload) == "Bytes":
        return "InvalidBytes"
    format_name = payload(wrapper_payload)
    return "WrongValueKind:wrapper text" if format_name is None else f"Format:{format_name}"


def wrapDecode(profile, wrapper_name, value):
    text = _wrapper_text(profile, wrapper_name, value)
    if text is None:
        raise ValueFailure(wrapper_name, (), "InvalidWrapper", value)
    return text


def withMember(key, text, value):
    if not isinstance(value, Mapping):
        raise ValueFailure(key, (), "WrongValueKind:object", value)
    return {key: text, **{name: item for name, item in value.items() if name != key}}


def _field(value, name, default=None):
    return value.get(name, default) if isinstance(value, Mapping) else getattr(value, name, default)


def _named(values, name):
    return next((value for value in values if _field(value, "name") == name), None)


def _unit(value):
    return sum_tag(value) if isinstance(value, Mapping) else value


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


def _string_condition(profile, spec, text):
    if not _unicode_scalar_text(text):
        return "InvalidDataModel"
    if spec["const_value"] is not None and text != spec["const_value"]:
        return "ConstMismatch"
    if spec["enum_values"] is not None and text not in spec["enum_values"]:
        return "EnumMismatch"
    for bound in spec["lengths"]:
        length = _length(profile, bound["unit"], text)
        if length is None or bound["minimum"] is not None and length < integer(bound["minimum"]) or bound["maximum"] is not None and length > integer(bound["maximum"]):
            return "StringLength"
    if not _format(profile, spec["format"], text):
        name = payload(spec["format"]) if sum_tag(spec["format"]) == "Named" else "inline"
        return f"Format:{name}"
    return None


def recognize_language_tag(text: str, grandfathered) -> bool:
    if not text or not text.isascii():
        return False
    text = text.lower()
    if any(entry.isascii() and text == entry.lower() for entry in grandfathered):
        return True
    parts = text.split("-")
    language = parts[0]
    if language == "x":
        return len(parts) > 1 and all(
            1 <= len(part) <= 8 and part.isalnum() for part in parts[1:]
        )
    if not 2 <= len(language) <= 8 or not language.isalpha():
        return False
    index = 1
    if len(language) <= 3:
        for _ in range(3):
            if index < len(parts) and len(parts[index]) == 3 and parts[index].isalpha():
                index += 1
            else:
                break
    if index < len(parts) and len(parts[index]) == 4 and parts[index].isalpha():
        index += 1
    if index < len(parts) and (
        len(parts[index]) == 2 and parts[index].isalpha()
        or len(parts[index]) == 3 and parts[index].isdigit()
    ):
        index += 1
    variants = set()
    while index < len(parts):
        part = parts[index]
        if not (
            5 <= len(part) <= 8 and part.isalnum()
            or len(part) == 4 and part[0].isdigit() and part.isalnum()
        ):
            break
        if part in variants:
            return False
        variants.add(part)
        index += 1
    extensions = set()
    while (
        index < len(parts)
        and len(parts[index]) == 1
        and parts[index].isalnum()
        and parts[index] != "x"
    ):
        singleton = parts[index]
        if singleton in extensions:
            return False
        extensions.add(singleton)
        index += 1
        start = index
        while index < len(parts) and 2 <= len(parts[index]) <= 8 and parts[index].isalnum():
            index += 1
        if index == start:
            return False
    if index < len(parts) and parts[index] == "x":
        private = parts[index + 1:]
        return bool(private) and all(
            1 <= len(part) <= 8 and part.isalnum() for part in private
        )
    return index == len(parts)


def recognize_format(rule, text):
    if type(text) is not str:
        return False
    nodes = []

    def node(kind, spec, children=()):
        index = len(nodes)
        nodes.append((kind, spec, children))
        return index

    def binary_sequence(children, start, end):
        if start == end:
            return node("Epsilon", None)
        if end - start == 1:
            return children[start]
        middle = (start + end) // 2
        return node("Sequence", None, (
            binary_sequence(children, start, middle),
            binary_sequence(children, middle, end),
        ))

    def compile_rule(current):
        kind, spec = sum_tag(current), payload(current)
        if kind == "Sequence":
            children = [compile_rule(child) for child in spec]
            return binary_sequence(children, 0, len(children))
        if kind == "Choice":
            return node(kind, spec, tuple(compile_rule(child) for child in spec))
        if kind in ("Not", "Optional"):
            return node(kind, spec, (compile_rule(spec),))
        if kind in ("Bounded", "Labels"):
            return node(kind, spec, (compile_rule(spec["rule"]),))
        return node("Leaf", current)

    root = compile_rule(rule)
    memo = {}

    def accepts(index, start, end):
        key = (index, start, end)
        if key in memo:
            return memo[key]
        kind, spec, children = nodes[index]
        if kind == "Epsilon":
            accepted = start == end
        elif kind == "Sequence":
            accepted = any(
                accepts(children[0], start, split) and accepts(children[1], split, end)
                for split in range(start, end + 1)
            )
        elif kind == "Choice":
            accepted = any(accepts(child, start, end) for child in children)
        elif kind == "Optional":
            accepted = start == end or accepts(children[0], start, end)
        elif kind == "Not":
            accepted = not accepts(children[0], start, end)
        elif kind == "Bounded":
            length = len(text[start:end].encode()) if _unit(spec["unit"]) == "Utf8Bytes" else end - start
            accepted = length <= integer(spec["maximum"]) and accepts(children[0], start, end)
        elif kind == "Labels":
            separator = spec["separator"]
            parts = text[start:end].split(separator) if separator else []
            accepted = bool(separator) and len(parts) >= integer(spec["min_count"])
            accepted = accepted and (spec["max_count"] is None or len(parts) <= integer(spec["max_count"]))
            accepted = accepted and (spec["total_max"] is None or end - start <= integer(spec["total_max"]))
            cursor = start
            if accepted:
                for part in parts:
                    if not accepts(children[0], cursor, cursor + len(part)):
                        accepted = False
                        break
                    cursor += len(part) + len(separator)
        else:
            accepted = _recognize_format_leaf(spec, text[start:end])
        memo[key] = accepted
        return accepted

    return accepts(root, 0, len(text))


def _recognize_format_leaf(rule, text):
    kind, spec = sum_tag(rule), payload(rule)
    if kind == "Text": return True
    if kind == "Literal": return text == spec
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
    if kind == "LanguageTag": return recognize_language_tag(text, spec["grandfathered"])
    if kind == "Timestamp": return bool(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})", text))
    return False


def _base64_decode(policy, text):
    if type(text) is not str:
        return None
    parts = text.split("=")
    body, padding = parts[0], len(parts) - 1
    if padding > 2 or any(parts[1:]):
        return None
    standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    alphabet = {
        "Standard": standard,
        "UrlSafe": standard[:-2] + "-_",
        "Either": standard + "-_",
    }[_unit(policy["alphabet"])]
    if any(character not in alphabet for character in body):
        return None
    remainder = len(body) % 4
    if remainder == 1:
        return None
    normalized = body.replace("-", "+").replace("_", "/")
    if policy["strict_pad_bits"] and remainder in (2, 3):
        last = standard.index(normalized[-1])
        if remainder == 2 and last % 16 or remainder == 3 and last % 4:
            return None
    if padding and (len(text) % 4 or padding != (-remainder) % 4):
        return None
    if padding == 0 and not policy["padding_optional"] and remainder:
        return None
    return base64.b64decode(normalized + "=" * ((-len(normalized)) % 4))


def _bytes_text(profile, value):
    policy = profile.get("bytes_policy")
    if policy is None: return None
    wrapper = policy.get("wrapper")
    text = _wrapper_text(profile, wrapper, value) if wrapper is not None else value
    return _base64_decode(policy, text)


def classOf(profile, members):
    if isinstance(members, Mapping): members = list(members.items())
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
            if model is not None and isinstance(value, Mapping) and value.get(model["key"]) == branch["wire_tag"]: return index
        elif kind == "MemberShape" and isinstance(value, Mapping):
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
            actual = "Null" if value is None else "Boolean" if type(value) is bool else "Number" if isinstance(value, (int, DecimalLiteral, Decimal)) else "String" if type(value) is str else "Array" if isinstance(value, list) else "Object" if isinstance(value, Mapping) else "Unknown"
            if actual == expected: return index
        elif kind == "Otherwise": return index
    raise ValueFailure(reference, (), "NoBranchSelected", value)


def _freeze_json(value):
    if isinstance(value, Mapping):
        return MappingProxyType({key: _freeze_json(item) for key, item in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(_freeze_json(item) for item in value)
    return value


def _thaw_json(value):
    if isinstance(value, Mapping):
        return {key: _thaw_json(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_thaw_json(item) for item in value]
    return value


def _value_json(value):
    if isinstance(value, Mapping):
        return JsonObject((key, _value_json(item)) for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return [_value_json(item) for item in value]
    return value


@dataclass(frozen=True, slots=True)
class DefaultApplication:
    value_path: tuple
    type_ref: object
    origin: object
    value: object


@dataclass(frozen=True, slots=True, init=False)
class DefaultedValue:
    value: object
    applications: tuple[DefaultApplication, ...]


def _default_origin(reference):
    return {"source": reference["source"], "pointer": [*reference["pointer"], "default"]}


class ValueContext:
    @classmethod
    def from_signature_nodes(cls, profile, nodes):
        from .type_signatures import _graph
        return cls(_graph({"profile": profile, "nodes": nodes, "definitions": []}))

    def __init__(self, graph):
        self.graph = graph
        self.profile = graph["profile"]
        self.nodes = {}
        self.references = {}
        for node in graph.get("nodes", ()):
            reference = node["reference"]
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

    def _meaning_reasons(self, reference):
        node = self.nodes.get(ref_key(reference))
        if node is None:
            return [variant("UnresolvedType")]
        kind, spec = sum_tag(node["shape"]), payload(node["shape"])
        reasons = []
        if kind == "String":
            if any(sum_tag(bound["unit"]) == "Graphemes" for bound in spec["lengths"]) and self.profile.get("grapheme_rules") is None:
                reasons.append(variant("MissingGraphemeRules"))
            if spec["format"] is not None and sum_tag(spec["format"]) == "Named" and _named(self.profile.get("format_bindings", ()), payload(spec["format"])) is None:
                reasons.append(variant("UnknownFormat", payload(spec["format"])))
            if spec["wrapper"] is not None:
                wrapper = _named(self.profile.get("wrappers", ()), spec["wrapper"])
                if wrapper is None:
                    reasons.append(variant("UnknownWrapper", spec["wrapper"]))
                elif sum_tag(wrapper["payload"]) != "Text":
                    reasons.append(variant("WrapperPayload", spec["wrapper"]))
        elif kind == "Integer":
            domain_name = spec["domain"] or self.profile.get("default_integer_domain")
            binding = _named(self.profile.get("integer_domains", ()), domain_name)
            if binding is None:
                reasons.append(variant("UnknownIntegerDomain", domain_name))
            elif sum_tag(binding["range"]) == "Inclusive":
                domain = payload(binding["range"])
                if (spec["minimum"] is not None and integer(spec["minimum"]) < integer(domain["minimum"])) or (spec["maximum"] is not None and integer(spec["maximum"]) > integer(domain["maximum"])):
                    reasons.append(variant("IntegerBound"))
        elif kind == "Decimal" and not self.profile.get("numbers", {}).get("decimals", False):
            reasons.append(variant("DecimalNotAdmitted"))
        elif kind in ("Bytes", "RawBody") and self.profile.get("bytes_policy") is None:
            reasons.append(variant("MissingBytesPolicy"))
        elif kind == "Sealed":
            model = self.profile.get("tag")
            if model is None or not any(form["tag"] == spec["tag"] for form in model["sealed"]):
                reasons.append(variant("UnknownSealedTag", spec["tag"]))
        elif kind == "TaggedUnion" and any(sum_tag(branch["selector"]) == "InternalTag" for branch in spec["branches"]) and self.profile.get("tag") is None:
            reasons.append(variant("MissingTagModel"))
        elif kind == "Opaque":
            reasons.append(variant("OpaqueType", spec["type_name"]))
        return reasons

    def _type_children(self, reference):
        node = self.nodes.get(ref_key(reference))
        if node is None:
            return []
        kind, spec = sum_tag(node["shape"]), payload(node["shape"])
        if kind == "Product":
            return [field["slot"]["type_ref"] for field in spec["fields"]] + ([payload(spec["extras"])["value"]["type_ref"]] if sum_tag(spec["extras"]) == "Allow" else [])
        if kind == "Array":
            return [spec["item"]["type_ref"]]
        if kind == "Alias":
            return [spec["target"]]
        if kind == "TaggedUnion":
            return [branch["target"] for branch in spec["branches"]]
        return []

    def meaning_obligations(self, reference):
        pending = [self.reference(reference)]
        seen = set()
        reachable = []
        edges = sum(len(self._type_children(node["reference"])) for node in self.nodes.values())
        for _ in range(1 + len(self.nodes) + edges + 1):
            if not pending:
                break
            current = self.reference(pending.pop(0))
            key = ref_key(current)
            if key in seen:
                continue
            seen.add(key)
            reachable.insert(0, current)
            pending[:0] = self._type_children(current)
        return [{"type_ref": current, "origin": {"source": current["source"], "pointer": current["pointer"]}, "value_path": [], "profile": self.profile["reference"], "reason": reason}
                for current in reachable for reason in self._meaning_reasons(current)]

    def check_meaning(self, reference):
        predicates = {"UnknownFormat": "MO01", "MissingGraphemeRules": "MO02", "MissingBytesPolicy": "MO03", "UnknownIntegerDomain": "MO04", "UnknownWrapper": "MO05", "WrapperPayload": "MO06", "UnknownSealedTag": "MO07", "DecimalNotAdmitted": "MO08", "IntegerBound": "MO09", "OpaqueType": "MO10", "MissingTagModel": "MO11"}
        for obligation in self.meaning_obligations(reference):
            predicate = predicates.get(obligation["reason"]["tag"])
            if predicate is not None:
                raise MeaningFailure(obligation["type_ref"], predicate)

    def _checked_materialization_value(self, reference, value):
        obligations = self.meaning_obligations(reference)
        if obligations:
            raise UnresolvedValueFailure(obligations)
        return self.validate(reference, value)

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
        return self.validate(contract["type_ref"], value, path, active, evaluation_path)

    def validate(self, reference, value, path=(), active=(), evaluation_path=None):
        if not active:
            value = _value_json(value)
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
        if isinstance(value, Mapping) and kind in ("Product", "Unknown", "Sealed", "TaggedUnion"):
            seen = set()
            for name, _ in value.items():
                if name in seen:
                    reject(f"DuplicateField:{name}")
                seen.add(name)
        if kind == "Alias":
            return self.validate(spec["target"], value, path, next_active, evaluation_path)
        if kind == "Never": reject("InvalidDataModel")
        if kind == "Opaque": reject("Unresolved:opaque")
        if kind == "Unit":
            if value is not None: reject("WrongValueKind:null")
        elif kind == "Unknown":
            if isinstance(value, Mapping): self._validate_tag_member(reference, value, path, trace)
            if sum_tag(spec) == "OrdinaryObject" and (not isinstance(value, Mapping) or classOf(self.profile, value)[0] != "Ordinary"): reject("WrongValueKind:ordinary object")
            self._validate_data(reference, value, path, trace)
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
            text = value
            if spec["wrapper"] is not None:
                classification, wrapper = classOf(self.profile, value) if isinstance(value, Mapping) else ("Ordinary", None)
                if classification != "Wrapper" or wrapper["name"] != spec["wrapper"]:
                    reject("WrongValueKind:string wrapper")
                text = _wrapper_text(self.profile, wrapper["name"], value)
                if text is None:
                    reject(_wrapper_payload_failure(wrapper))
            if type(text) is not str: reject("WrongValueKind:string")
            condition = _string_condition(self.profile, spec, text)
            if condition is not None: reject(condition)
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
            if not isinstance(value, Mapping): reject("WrongValueKind:object")
            self._validate_tag_member(reference, value, path, trace)
            fields = {field["wire_name"]: field for field in spec["fields"]}
            for name, field in fields.items():
                if name not in value:
                    if field["slot"]["required"]:
                        raise ValueFailure(self.reference(field["slot"]["type_ref"]), (*path, name), "MissingRequired", "absent", trace)
                elif value[name] is None:
                    if not field["slot"]["nullable"]:
                        raise ValueFailure(self.reference(field["slot"]["type_ref"]), (*path, name), "NullNotAllowed", None, trace)
                else: self.validate(field["slot"]["type_ref"], value[name], (*path, name), next_active, (*evaluation_path, name))
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
            if isinstance(value, Mapping): self._validate_tag_member(reference, value, path, trace)
            if not isinstance(value, Mapping) or classOf(self.profile, value)[0] != "Sealed":
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
            if isinstance(value, Mapping): self._validate_tag_member(reference, value, path, trace)
            index = selectBranch(self, reference, value)
            self.validate(spec["branches"][index]["target"], value, path, next_active, evaluation_path)
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
            text = value
            if isinstance(value, Mapping):
                classification, wrapper = classOf(self.profile, value)
                text = _wrapper_text(self.profile, wrapper["name"], value) if classification == "Wrapper" else None
                if classification == "Wrapper" and text is None:
                    raise ValueFailure(reference, path, _wrapper_payload_failure(wrapper), value)
            if type(text) is not str: raise ValueFailure(reference, path, "WrongValueKind:string", value)
            condition = _string_condition(self.profile, spec, text)
            if condition is not None:
                raise ValueFailure(reference, path, condition, value)
        else:
            parsed, failure = _integer_value(self.profile, spec, value)
            if failure: raise ValueFailure(reference, path, failure, value)
        return value

    def _validate_data(self, reference, value, path, trace):
        def reject(condition, observed=value, at=path):
            raise ValueFailure(reference, at, condition, observed, trace)
        if type(value) is int:
            _, failure = _integer_value(self.profile, {}, value)
            if failure:
                reject("IntegerDomain")
        elif isinstance(value, (float, DecimalLiteral, Decimal)):
            text = value.spelling if isinstance(value, DecimalLiteral) else str(value)
            if re.fullmatch(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?", text) is None:
                reject("InvalidDataModel")
            decimal_value = Decimal(text)
            if not decimal_value.is_finite():
                reject("InvalidDataModel")
            default_name = self.profile.get("default_integer_domain")
            binding = _named(self.profile.get("integer_domains", ()), default_name)
            integral_form = binding is not None and "IntegralDecimal" in {
                _unit(form) for form in binding.get("forms", ())
            }
            if integral_form and decimal_value == decimal_value.to_integral_value():
                domain = binding.get("range", {"tag": "Unbounded"})
                if sum_tag(domain) == "Inclusive":
                    bounds = payload(domain)
                    if decimal_value < Decimal(integer(bounds["minimum"])) or decimal_value > Decimal(integer(bounds["maximum"])):
                        reject("IntegerDomain")
                return
            if not self.profile.get("numbers", {}).get("decimals", False):
                reject("InvalidDataModel")
        elif type(value) is str:
            if not _unicode_scalar_text(value):
                reject("InvalidDataModel")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                self._validate_data(reference, child, (*path, index), trace)
        elif isinstance(value, Mapping):
            seen = set()
            for name, _ in value.items():
                if name in seen:
                    reject(f"DuplicateField:{name}")
                seen.add(name)
            self._validate_tag_member(reference, value, path, trace)
            classification, declaration = classOf(self.profile, value)
            if classification == "Wrapper":
                if _wrapper_text(self.profile, declaration["name"], value) is None:
                    reject(_wrapper_payload_failure(declaration))
                return
            known = set()
            if classification == "Sealed":
                known.add(self.profile["tag"]["key"])
                for field in declaration["fields"]:
                    name = field["key"]
                    known.add(name)
                    if name in value:
                        self._validate_leaf(reference, field["leaf"], value[name], (*path, name))
                    elif field["required"]:
                        reject("MissingRequired", None, (*path, name))
            for name, child in value.items():
                if name in known:
                    continue
                if classification == "Sealed" and sum_tag(declaration["extras"]) == "Reject":
                    reject(f"UnexpectedField:{name}", child, (*path, name))
                if not _unicode_scalar_text(name):
                    reject("InvalidDataModel", child, (*path, name))
                self._validate_data(reference, child, (*path, name), trace)

    def decode(self, reference, value):
        self.validate(reference, value)
        return value

    def _declared_default(self, reference):
        for _ in range(len(self.nodes) + 1):
            reference = self.reference(reference)
            node = self.nodes.get(ref_key(reference))
            if node is None:
                return None
            shape = node["shape"]
            kind, spec = sum_tag(shape), payload(shape)
            if kind == "Alias":
                reference = spec["target"]
            else:
                if kind in ("Boolean", "Integer", "String") and spec["default_value"] is not None:
                    value = integer(spec["default_value"]) if kind == "Integer" else spec["default_value"]
                    return reference, value
                return None
        return None

    def _default_draft(self, reference, value, path, fuel):
        reference = self.reference(reference)
        if fuel == 0:
            raise ValueFailure(reference, path, "MembershipBound", value)
        node = self.nodes.get(ref_key(reference))
        if node is None:
            raise ValueFailure(reference, path, "UnresolvedType", value)
        kind, spec = sum_tag(node["shape"]), payload(node["shape"])
        if kind == "Alias":
            return self._default_draft(spec["target"], value, path, fuel - 1)
        if kind == "TaggedUnion" and isinstance(value, Mapping):
            key = (self.profile.get("tag") or {}).get("key", "")
            tag = value.get(key)
            branch = next((branch for branch in spec["branches"] if type(tag) is str and branch["wire_tag"] == tag), None)
            if branch is not None:
                return self._default_draft(branch["target"], value, path, fuel - 1)
        applications = []
        if kind == "Array" and type(value) is list:
            output = []
            for index, item in enumerate(value):
                after, evidence = self._default_draft(spec["item"]["type_ref"], item, (*path, index), fuel - 1)
                output.append(after)
                applications.extend(evidence)
            return output, applications
        if kind == "Product" and isinstance(value, Mapping):
            output = []
            fields = {field["wire_name"]: field for field in spec["fields"]}
            for key, item in value.items():
                if key in fields and item is not None:
                    item, evidence = self._default_draft(fields[key]["slot"]["type_ref"], item, (*path, key), fuel - 1)
                    applications.extend(evidence)
                output.append((key, item))
            for field in spec["fields"]:
                key = field["wire_name"]
                if key in value:
                    continue
                declared = self._declared_default(field["slot"]["type_ref"])
                if declared is not None:
                    default_ref, item = declared
                    self._checked_materialization_value(default_ref, item)
                    applications.append(DefaultApplication((*path, key), _freeze_json(default_ref), _freeze_json(_default_origin(default_ref)), _freeze_json(item)))
                    output.append((key, item))
            return JsonObject(output), applications
        return value, applications

    def check_default_applications(self, before, after, applications):
        def at(value, path):
            for step in path:
                if value is None:
                    return None
                if isinstance(step, str) and isinstance(value, Mapping):
                    value = value.get(step, ABSENT)
                elif isinstance(step, int) and isinstance(value, (list, tuple)) and 0 <= step < len(value):
                    value = value[step]
                else:
                    return ABSENT
            return value
        for application in applications:
            reference = _thaw_json(application.type_ref)
            node = self.nodes.get(ref_key(reference))
            if node is None:
                return False
            kind, spec = sum_tag(node["shape"]), payload(node["shape"])
            default = spec.get("default_value") if kind in ("Boolean", "Integer", "String") else None
            if default is None:
                return False
            default = integer(default) if kind == "Integer" else default
            if (not isinstance(at(before, application.value_path), Absent)
                or at(after, application.value_path) != application.value
                or _thaw_json(application.origin) != _default_origin(reference)
                or default != application.value):
                return False
        return True

    def materialize_defaults(self, reference, value):
        value = _value_json(value)
        def size(item):
            return 1 + (sum(size(child) for _, child in item.items()) if isinstance(item, Mapping) else sum(size(child) for child in item) if type(item) is list else 0)
        after, applications = self._default_draft(reference, value, (), (size(value) + 1) * (len(self.nodes) + 1))
        self._checked_materialization_value(reference, after)
        if not self.check_default_applications(value, after, applications):
            raise ValueFailure(self.reference(reference), (), "CertificateMismatch:default source, absence, or result")
        result = object.__new__(DefaultedValue)
        object.__setattr__(result, "value", _freeze_json(after))
        object.__setattr__(result, "applications", tuple(applications))
        return result

    def decode_with_defaults(self, reference, text):
        return self.materialize_defaults(reference, decode_wire_json(text))

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
