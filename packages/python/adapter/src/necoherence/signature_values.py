# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Semantic values and runtime operations for checked signature libraries."""
from __future__ import annotations

import bisect
import heapq
import json
import re
import sys
from collections import deque
from collections.abc import Mapping
from dataclasses import dataclass, field as dataclass_field
from decimal import Decimal
from enum import Enum
from typing import TypeAlias

import neco_quotient_certificate as nqc


_DECIMAL_SPELLING = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")


@dataclass(frozen=True, slots=True)
class DecimalLiteral:
    spelling: str

    def __post_init__(self):
        if not isinstance(self.spelling, str) or _DECIMAL_SPELLING.fullmatch(self.spelling) is None:
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
class Absent:
    pass


ABSENT = Absent()


@dataclass(frozen=True, slots=True)
class AbsentValue:
    pass


@dataclass(frozen=True, slots=True)
class NullValue:
    pass


@dataclass(frozen=True, slots=True)
class PresentValue:
    value: object


ABSENT_VALUE = AbsentValue()
NULL_VALUE = NullValue()
SlotValue: TypeAlias = AbsentValue | NullValue | PresentValue


class ValueConditionTag(Enum):
    MISSING_REQUIRED = "MissingRequired"
    NULL_NOT_ALLOWED = "NullNotAllowed"
    WRONG_VALUE_KIND = "WrongValueKind"
    CONST_MISMATCH = "ConstMismatch"
    ENUM_MISMATCH = "EnumMismatch"
    BELOW_MINIMUM = "BelowMinimum"
    ABOVE_MAXIMUM = "AboveMaximum"
    INTEGER_DOMAIN = "IntegerDomain"
    STRING_LENGTH = "StringLength"
    ARRAY_LENGTH = "ArrayLength"
    BYTES_LENGTH = "BytesLength"
    FORMAT = "Format"
    INVALID_BYTES = "InvalidBytes"
    INVALID_WRAPPER = "InvalidWrapper"
    INVALID_TAG = "InvalidTag"
    RESERVED_FORM = "ReservedForm"
    NO_BRANCH_SELECTED = "NoBranchSelected"
    KEY_FORMAT = "KeyFormat"
    UNINHABITED = "Uninhabited"
    DUPLICATE_FIELD = "DuplicateField"
    UNEXPECTED_FIELD = "UnexpectedField"
    INVALID_DATA_MODEL = "InvalidDataModel"
    REFERENCE_CYCLE = "ReferenceCycle"


_VALUED_CONDITIONS = {
    ValueConditionTag.WRONG_VALUE_KIND,
    ValueConditionTag.FORMAT,
    ValueConditionTag.INVALID_WRAPPER,
    ValueConditionTag.KEY_FORMAT,
    ValueConditionTag.DUPLICATE_FIELD,
    ValueConditionTag.UNEXPECTED_FIELD,
}


@dataclass(frozen=True, slots=True)
class ValueCondition:
    tag: ValueConditionTag
    value: str | None = None

    def __post_init__(self):
        if (self.tag in _VALUED_CONDITIONS) != (self.value is not None):
            raise ValueError("invalid value condition")


MISSING_REQUIRED = ValueCondition(ValueConditionTag.MISSING_REQUIRED)
NULL_NOT_ALLOWED = ValueCondition(ValueConditionTag.NULL_NOT_ALLOWED)
CONST_MISMATCH = ValueCondition(ValueConditionTag.CONST_MISMATCH)
ENUM_MISMATCH = ValueCondition(ValueConditionTag.ENUM_MISMATCH)
BELOW_MINIMUM = ValueCondition(ValueConditionTag.BELOW_MINIMUM)
ABOVE_MAXIMUM = ValueCondition(ValueConditionTag.ABOVE_MAXIMUM)
INTEGER_DOMAIN = ValueCondition(ValueConditionTag.INTEGER_DOMAIN)
STRING_LENGTH = ValueCondition(ValueConditionTag.STRING_LENGTH)
ARRAY_LENGTH = ValueCondition(ValueConditionTag.ARRAY_LENGTH)
BYTES_LENGTH = ValueCondition(ValueConditionTag.BYTES_LENGTH)
INVALID_BYTES = ValueCondition(ValueConditionTag.INVALID_BYTES)
INVALID_TAG = ValueCondition(ValueConditionTag.INVALID_TAG)
RESERVED_FORM = ValueCondition(ValueConditionTag.RESERVED_FORM)
NO_BRANCH_SELECTED = ValueCondition(ValueConditionTag.NO_BRANCH_SELECTED)
UNINHABITED = ValueCondition(ValueConditionTag.UNINHABITED)
INVALID_DATA_MODEL = ValueCondition(ValueConditionTag.INVALID_DATA_MODEL)
REFERENCE_CYCLE = ValueCondition(ValueConditionTag.REFERENCE_CYCLE)


def wrong_value_kind(expected: str) -> ValueCondition:
    return ValueCondition(ValueConditionTag.WRONG_VALUE_KIND, expected)


def format_condition(name: str) -> ValueCondition:
    return ValueCondition(ValueConditionTag.FORMAT, name)


def invalid_wrapper(name: str) -> ValueCondition:
    return ValueCondition(ValueConditionTag.INVALID_WRAPPER, name)


def key_format(name: str) -> ValueCondition:
    return ValueCondition(ValueConditionTag.KEY_FORMAT, name)


def duplicate_field(name: str) -> ValueCondition:
    return ValueCondition(ValueConditionTag.DUPLICATE_FIELD, name)


def unexpected_field(name: str) -> ValueCondition:
    return ValueCondition(ValueConditionTag.UNEXPECTED_FIELD, name)


class Uninhabited:
    def __new__(cls, *args, **kwargs):
        raise TypeError("uninhabited type")


class MeaningFailure(ValueError):
    def __init__(self, type_ref, predicate, location):
        self.type_ref = type_ref
        self.predicate = predicate
        self.location = tuple(location)
        super().__init__(f"{predicate} at {type_ref}")

MEANING_PREDICATES = {
    "UnknownFormat": "MO01",
    "MissingGraphemeRules": "MO02",
    "MissingBytesPolicy": "MO03",
    "UnknownIntegerDomain": "MO04",
    "UnknownWrapper": "MO05",
    "WrapperPayload": "MO06",
    "UnknownSealedTag": "MO07",
    "DecimalNotAdmitted": "MO08",
    "IntegerBound": "MO09",
    "OpaqueType": "MO10",
    "MissingTagModel": "MO11",
    "UnresolvedType": "MO12",
}


class ValueFailure(ValueError):
    def __init__(self, reference, path, condition: ValueCondition, observed: SlotValue, trace=()):
        self.type_ref = reference
        self.definition_ref = {"source": reference["source"], "name": reference["definition_name"]} if isinstance(reference, Mapping) else None
        self.origin = {"source": reference["source"], "pointer": reference["pointer"]} if isinstance(reference, Mapping) else None
        self.value_path = tuple(path)
        self.condition = condition
        self.observed = observed
        self.reference_trace = tuple(trace)
        super().__init__(f"{reference} {self.value_path}: {condition.tag.value}")


@dataclass(frozen=True, slots=True)
class SemanticJudgment:
    obligations: tuple
    provenance: object


@dataclass(frozen=True, slots=True)
class SemanticDecisionFailure:
    obligations: tuple
    residuals: nqc.ResidualSet
    classifications: tuple
    provenance: object


type SemanticEvaluation = nqc.RefinementOutcome[SemanticJudgment, object, tuple] | SemanticDecisionFailure


def semantic_reason_disposition(reason):
    match reason["tag"]:
        case "UnknownFormat" | "MissingGraphemeRules" | "MissingBytesPolicy" | "UnknownIntegerDomain" | "UnknownWrapper" | "UnknownSealedTag" | "OpaqueType" | "MissingTagModel" | "UninterpretedExtension" | "UnresolvedType" | "ProjectionUnavailable":
            return "Residual"
        case "MembershipBound":
            return "Stopped"
        case "WrapperPayload" | "DecimalNotAdmitted" | "IntegerBound" | "InvalidProfile" | "CertificateMismatch":
            return "Failed"
    raise ValueError("unknown semantic reason")


def classify_dispositions(classes):
    if not classes:
        return "Failed"
    if "Failed" in classes:
        return "Failed"
    if "Stopped" in classes:
        return "Stopped"
    return "Residual"


def semantic_obligations_with(obligations, disposition):
    return tuple(item for item in obligations if semantic_reason_disposition(item["reason"]) == disposition)


def classify_semantic_obligations(obligations, provenance):
    reasons = tuple(obligations)
    classifications = tuple(semantic_reason_disposition(item["reason"]) for item in reasons)
    residuals = nqc.ResidualSet(semantic_obligations_with(reasons, "Residual"))
    judgment = SemanticJudgment(reasons, provenance)
    match classify_dispositions(classifications):
        case "Residual":
            return nqc.Residual(judgment, residuals)
        case "Stopped":
            return nqc.Stopped(judgment, residuals, semantic_obligations_with(reasons, "Stopped"))
    return SemanticDecisionFailure(reasons, residuals, classifications, provenance)


class UnresolvedValueFailure(ValueError):
    def __init__(self, obligations):
        self.obligations = tuple(obligations)
        super().__init__("unresolved value")


class CertificateMismatchFailure(ValueError):
    def __init__(self, condition: str):
        self.condition = condition
        super().__init__(condition)


class WireFailure(ValueError):
    def __init__(self, kind: str, path: str = "$", observed=None):
        self.kind = kind
        self.path = path
        self.observed = observed
        super().__init__(f"{path}: {kind}" + ("" if observed is None else f": {observed}"))


class JsonFailure(WireFailure):
    def __init__(self, observed=None):
        super().__init__("Syntax", "$", observed)


_INTEGER_CHUNK = 4000
_INTEGER_SCALE = 10 ** _INTEGER_CHUNK


def integer_from_digits(text):
    digits = text[1:] if text.startswith("-") else text
    value = 0
    for start in range(0, len(digits), _INTEGER_CHUNK):
        chunk = digits[start:start + _INTEGER_CHUNK]
        value = value * 10 ** len(chunk) + int(chunk)
    return -value if text.startswith("-") else value


def integer_digits(value):
    if value < 0: return "-" + integer_digits(-value)
    chunks = []
    while value >= _INTEGER_SCALE:
        value, rest = divmod(value, _INTEGER_SCALE)
        chunks.append(f"{rest:0{_INTEGER_CHUNK}d}")
    return str(value) + "".join(reversed(chunks))


def sum_tag(value):
    return value["tag"]


def payload(value):
    return value.get("value", value.get("fields"))


def variant(name, value=ABSENT, *, fields=None):
    if fields is not None:
        return {"tag": name, "fields": fields}
    return {"tag": name} if value is ABSENT else {"tag": name, "value": value}


_CANONICAL_ESCAPES = {ord('"'): '\\"', ord("\\"): "\\\\", ord("\n"): "\\n", ord("\r"): "\\r"}
_CANONICAL_ESCAPES.update((code, "\\u%04x" % code) for code in range(0x20) if code not in (0x0A, 0x0D))


def canonical_string(text):
    if not isinstance(text, str): raise TypeError("string required")
    return '"' + text.translate(_CANONICAL_ESCAPES) + '"'


class _Raw:
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text


def canonical_json(value, number):
    parts, pending = [], [value]
    while pending:
        item = pending.pop()
        if type(item) is _Raw: parts.append(item.text)
        elif item is None: parts.append("null")
        elif item is True: parts.append("true")
        elif item is False: parts.append("false")
        elif type(item) is int: parts.append(integer_digits(item))
        elif type(item) is str: parts.append(canonical_string(item))
        elif isinstance(item, (list, tuple)):
            parts.append("[")
            pending.append(_Raw("]"))
            for index in range(len(item) - 1, -1, -1):
                pending.append(item[index])
                if index: pending.append(_Raw(","))
        elif isinstance(item, Mapping):
            parts.append("{")
            pending.append(_Raw("}"))
            keys = sorted(item)
            for index in range(len(keys) - 1, -1, -1):
                pending.append(item[keys[index]])
                pending.append(_Raw(canonical_string(keys[index]) + ":"))
                if index: pending.append(_Raw(","))
        else: parts.append(number(item))
    return "".join(parts)


def _wire_number(value):
    raise TypeError("wire value required")


def _exact_number(value):
    if isinstance(value, DecimalLiteral): spelling = value.spelling
    elif isinstance(value, Decimal) and value.is_finite(): spelling = str(value)
    else: raise TypeError("exact JSON value required")
    if json_text_exponent_too_large(spelling): raise JsonFailure("exponent too large")
    return json_decimal_text(*json_number_parts(spelling))


def canonical_wire(value):
    return canonical_json(value, _wire_number)


def declared_type_ref(reference):
    if isinstance(reference, str):
        return {"source": {"repository": "ncoh-type-signatures", "revision": "1", "path": "", "content_digest": "", "document_id": "", "declared_revision": None},
                "definition_name": reference, "pointer": []}
    return reference


def ref_key(reference):
    if isinstance(reference, str):
        return reference
    if isinstance(reference, Mapping):
        return canonical_wire(reference)
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
    return integer_from_digits(value)


def _rebuild(root, children, leaf, build):
    order, pending = [], [root]
    while pending:
        node = pending.pop()
        kids = children(node)
        if kids is None: continue
        kids = list(kids)
        order.append((node, kids))
        pending.extend(kids)
    built = {}
    for node, kids in reversed(order):
        built[id(node)] = build(node, [built[id(kid)] if id(kid) in built else leaf(kid) for kid in kids])
    return built[id(root)] if id(root) in built else leaf(root)


_EXACT_LEAF_KINDS = ("Null", "Bool", "Integer", "Decimal", "String")


def _exact_decode_children(value):
    kind = sum_tag(value)
    if kind == "Array": return value["items"]
    if kind in _EXACT_LEAF_KINDS: return None
    return [item["value"] for item in value["members"]]


def _exact_decode_leaf(value):
    kind = sum_tag(value)
    if kind == "Null": return None
    if kind == "Bool": return payload(value)
    if kind == "Integer": return integer(payload(value))
    if kind == "Decimal": return DecimalLiteral(value["text"])
    return payload(value)


def _exact_decode_build(value, results):
    if sum_tag(value) == "Array": return results
    return JsonObject((item["key"], result) for item, result in zip(value["members"], results))


def exact_decode(value):
    return _rebuild(value, _exact_decode_children, _exact_decode_leaf, _exact_decode_build)


def _exact_encode_children(value):
    if isinstance(value, (list, tuple)): return value
    if isinstance(value, Mapping): return [child for _, child in value.items()]
    return None


def _exact_encode_leaf(value):
    if value is None: return variant("Null")
    if type(value) is bool: return variant("Bool", value)
    if type(value) is int: return variant("Integer", integer_digits(value))
    if isinstance(value, (Decimal, DecimalLiteral)): return {"tag": "Decimal", "text": str(value)}
    if type(value) is str: return variant("String", value)
    raise TypeError("exact JSON value required")


def _exact_encode_build(value, results):
    if isinstance(value, (list, tuple)): return {"tag": "Array", "items": results}
    return {"tag": "Object", "members": [{"key": key, "value": result} for (key, _), result in zip(value.items(), results)]}


def exact_encode(value):
    return _rebuild(value, _exact_encode_children, _exact_encode_leaf, _exact_encode_build)


EXPONENT_LIMIT = 10000
_JSON_EXPONENT = re.compile(r"[+-]?([0-9]+)")
_JSON_HEX4 = re.compile(r"[0-9a-fA-F]{4}")


def json_exponent_reaches_limit(digits):
    significant = digits.lstrip("0")
    return len(significant) > len(str(EXPONENT_LIMIT)) or (significant != "" and int(significant) >= EXPONENT_LIMIT)


def json_text_exponent_too_large(text):
    index, in_string = 0, False
    while index < len(text):
        char = text[index]
        if char == '"':
            in_string = not in_string
        elif in_string and char == "\\":
            index += 1
        elif not in_string and char in "eE":
            matched = _JSON_EXPONENT.match(text, index + 1)
            if matched is not None and json_exponent_reaches_limit(matched.group(1)): return True
        index += 1
    return False


def _json_hex4(text, index):
    matched = _JSON_HEX4.match(text, index)
    return None if matched is None else int(matched.group(), 16)


def _admit_json_text(text):
    index, in_string, end = 0, False, len(text)
    while index < end:
        char = text[index]
        if not in_string:
            if char == '"':
                in_string = True
            elif char in "eE":
                matched = _JSON_EXPONENT.match(text, index + 1)
                if matched is not None and json_exponent_reaches_limit(matched.group(1)):
                    raise JsonFailure("exponent too large")
            index += 1
        elif char == '"':
            in_string = False
            index += 1
        elif char == "\\" and text[index + 1:index + 2] == "u":
            code = _json_hex4(text, index + 2)
            if code is None:
                index += 2
            elif 0xDC00 <= code <= 0xDFFF:
                raise JsonFailure("unpaired Unicode surrogate")
            elif 0xD800 <= code <= 0xDBFF:
                low = _json_hex4(text, index + 8) if text[index + 6:index + 8] == "\\u" else None
                if low is None or not 0xDC00 <= low <= 0xDFFF:
                    raise JsonFailure("unpaired Unicode surrogate")
                index += 12
            else:
                index += 6
        elif char == "\\":
            index += 2 if index + 1 < end else 1
        else:
            index += 1


_JSON_NUMBER_FIELDS = re.compile(r"(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?)([0-9]+))?")


def json_number_parts(spelling):
    matched = _JSON_NUMBER_FIELDS.fullmatch(spelling)
    if matched is None: raise ValueError("JSON number required")
    sign, whole, fraction, exponent_sign, exponent = matched.groups()
    fraction = fraction or ""
    mantissa, scale = (-1 if sign else 1) * integer_from_digits(whole + fraction), len(fraction)
    if exponent:
        count = integer_from_digits(exponent)
        if exponent_sign == "-": scale += count
        else:
            mantissa *= 10 ** max(0, count - scale)
            scale = max(0, scale - count)
    return mantissa, scale


def json_number_text(mantissa, scale):
    if scale == 0: return integer_digits(mantissa)
    sign = "" if mantissa >= 0 else "-"
    magnitude = abs(mantissa)
    exponent = min(9 + len(integer_digits(magnitude)) - scale, 0)
    unit = 10 ** (scale - abs(exponent))
    left = integer_digits(magnitude // unit)
    if magnitude % unit == 0 and exponent == 0: return sign + left
    right = integer_digits(unit + magnitude % unit)[1:].rstrip("0")
    return f"{sign}{left}.{right}" + ("" if exponent == 0 else f"e{exponent}")


def json_decimal_text(mantissa, scale):
    unit = 10 ** scale
    if mantissa % unit == 0: return f"{integer_digits(mantissa // unit)}.0"
    return json_number_text(mantissa, scale)


def _exact_scalar(value):
    if isinstance(value, DecimalLiteral):
        if json_text_exponent_too_large(value.spelling): raise JsonFailure("exponent too large")
        mantissa, scale = json_number_parts(value.spelling)
        if scale == 0: return mantissa
        return DecimalLiteral("0") if mantissa == 0 else DecimalLiteral(json_number_text(mantissa, scale))
    return value


def exact_from_json(value):
    return _convert_tree(value, (list,), _exact_scalar, sorted_keys=True)


@dataclass(frozen=True, slots=True)
class RawJsonNumber:
    text: str


def json_output_number(literal):
    return RawJsonNumber(json_decimal_text(*json_number_parts(literal.spelling)))


def decode_wire_json(text: str):
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                raise JsonFailure(f"duplicate object key: {key}")
            result[key] = value
        return result
    _admit_json_text(text)
    try:
        return json.loads(text, object_pairs_hook=pairs, parse_int=integer_from_digits, parse_float=DecimalLiteral,
                          parse_constant=lambda text: (_ for _ in ()).throw(ValueError(text)))
    except JsonFailure:
        raise
    except (ValueError, json.JSONDecodeError) as error:
        raise JsonFailure(str(error)) from None


def encode_wire_json(value):
    return canonical_json(value, _exact_number)


def wrapEncode(profile, wrapper_name, value):
    wrapper = _named(profile.get("wrappers", ()), wrapper_name)
    if wrapper is None:
        raise ValueFailure(wrapper_name, (), invalid_wrapper(wrapper_name), PresentValue(value))
    return {wrapper["key"]: value}


def wrapDecode(profile, wrapper_name, value):
    wrapper = _named(profile.get("wrappers", ()), wrapper_name)
    text = None if wrapper is None else wrapper_payload_text(profile, wrapper, value)
    if text is None:
        raise ValueFailure(wrapper_name, (), invalid_wrapper(wrapper_name), PresentValue(value))
    return text


def withMember(key, text, value):
    if not isinstance(value, Mapping):
        raise ValueFailure(key, (), wrong_value_kind("object"), PresentValue(value))
    return {key: text, **{name: item for name, item in value.items() if name != key}}


def _named(values, name):
    return next((value for value in values if value["name"] == name), None)


def _scalar_valid(c):
    return ord(c) <= 1114111 and not (55296 <= ord(c) <= 57343)


def unicode_valid(text):
    return all(_scalar_valid(c) for c in text)


def utf8_length(text):
    return sum(1 if ord(c) < 128 else 2 if ord(c) < 2048 else 3 if ord(c) < 65536 else 4 for c in text)


def _grapheme_table(rows):
    table = [(integer(row["first"]), integer(row["last"]), sum_tag(row["property"]) if "property" in row else "") for row in rows]
    order = sorted(range(len(table)), key=lambda index: table[index][0])
    points = sorted({point for first, last, _ in table for point in (first, last + 1)})
    active, position, firsts, lasts, values = [], 0, [], [], []
    for start, stop in zip(points, points[1:]):
        while position < len(order) and table[order[position]][0] <= start:
            heapq.heappush(active, order[position])
            position += 1
        while active and table[active[0]][1] < start:
            heapq.heappop(active)
        if not active: continue
        value = table[active[0]][2]
        if lasts and lasts[-1] == start - 1 and values[-1] == value: lasts[-1] = stop - 1
        else:
            firsts.append(start)
            lasts.append(stop - 1)
            values.append(value)
    return firsts, lasts, values


def _table_property(table, codepoint):
    firsts, lasts, values = table
    index = bisect.bisect_right(firsts, codepoint) - 1
    return values[index] if index >= 0 and codepoint <= lasts[index] else None


class PreparedGraphemeRules(dict):
    __slots__ = ("tables",)


def build_grapheme_tables(rules):
    return (
        _grapheme_table(rules["properties"]),
        _grapheme_table(rules["indic_conjunct"]),
        _grapheme_table(rules["extended_pictographic"]),
    )


def prepare_grapheme_rules(rules):
    prepared = PreparedGraphemeRules(rules)
    prepared.tables = build_grapheme_tables(rules)
    return prepared


def prepare_profile(profile):
    rules = profile.get("grapheme_rules")
    return profile if rules is None else {**profile, "grapheme_rules": prepare_grapheme_rules(rules)}


def _grapheme_tables(rules):
    if isinstance(rules, PreparedGraphemeRules): return rules.tables
    return build_grapheme_tables(rules)


def _control_property(property):
    return property in ("Cr", "Lf", "Control")


def _grapheme_break(previous, next_property, indic, pictographic, regional_run, previous_zwj_after_pictographic, indic_consonant, indic_linker):
    if previous is None: return True
    if previous == "Cr" and next_property == "Lf": return False
    if _control_property(previous) or _control_property(next_property): return True
    if previous == "L" and next_property in ("L", "V", "Lv", "Lvt"): return False
    if previous in ("Lv", "V") and next_property in ("V", "T"): return False
    if previous in ("Lvt", "T") and next_property == "T": return False
    if next_property in ("Extend", "Zwj", "SpacingMark"): return False
    if previous == "Prepend": return False
    if indic == "Consonant" and indic_consonant and indic_linker: return False
    if pictographic and previous == "Zwj" and previous_zwj_after_pictographic: return False
    if previous == "RegionalIndicator" and next_property == "RegionalIndicator" and regional_run % 2 == 1: return False
    return True


def grapheme_length(rules, text):
    properties, indic_conjunct, extended_pictographic = _grapheme_tables(rules)
    count, previous, regional_run = 0, None, 0
    pictographic_extends = previous_zwj_after_pictographic = indic_consonant = indic_linker = False
    for c in text:
        codepoint = ord(c)
        next_property = _table_property(properties, codepoint) or "Other"
        indic = _table_property(indic_conjunct, codepoint) or "Other"
        pictographic = _table_property(extended_pictographic, codepoint) is not None
        if _grapheme_break(previous, next_property, indic, pictographic, regional_run, previous_zwj_after_pictographic, indic_consonant, indic_linker): count += 1
        regional_run = regional_run + 1 if next_property == "RegionalIndicator" else 0
        previous_zwj_after_pictographic = next_property == "Zwj" and pictographic_extends
        pictographic_extends = pictographic or (next_property == "Extend" and pictographic_extends)
        indic_linker = False if indic == "Consonant" else indic_consonant if indic == "Linker" else indic == "Extend" and indic_linker
        indic_consonant = True if indic == "Consonant" else indic in ("Extend", "Linker") and indic_consonant
        previous = next_property
    return count


def length_in_unit(profile, unit, text):
    return format_length(profile.get("grapheme_rules"), unit, text)


def length_accepts(minimum, maximum, length):
    return (minimum is None or integer(minimum) <= length) and (maximum is None or length <= integer(maximum))


def length_bounds_failure(profile, text, bounds):
    for bound in bounds:
        length = length_in_unit(profile, bound["unit"], text)
        if length is None or not length_accepts(bound["minimum"], bound["maximum"], length):
            return STRING_LENGTH
    return None


def named_format_accepts(profile, name, text):
    binding = _named(profile.get("format_bindings", ()), name)
    return binding is not None and format_accepts_fast(profile.get("grapheme_rules"), binding["rule"], text)


def format_use_accepts(profile, use, text):
    if sum_tag(use) == "Inline": return format_accepts_fast(profile.get("grapheme_rules"), payload(use), text)
    return named_format_accepts(profile, payload(use), text)


def format_rule_uses_graphemes(rule):
    kind, spec = sum_tag(rule), payload(rule)
    if kind == "Bounded" and sum_tag(spec["unit"]) == "Graphemes": return True
    if kind in ("Sequence", "Choice"): return format_rules_use_graphemes(spec)
    if kind in ("Optional", "Not"): return format_rule_uses_graphemes(spec)
    if kind in ("Labels", "Bounded"): return format_rule_uses_graphemes(spec["rule"])
    return False


def format_rules_use_graphemes(rules):
    return any(format_rule_uses_graphemes(child) for child in rules)


def format_use_uses_graphemes(profile, use):
    if sum_tag(use) == "Inline": return format_rule_uses_graphemes(payload(use))
    binding = _named(profile.get("format_bindings", ()), payload(use))
    return binding is not None and format_rule_uses_graphemes(binding["rule"])


def string_condition(profile, spec, value):
    if not unicode_valid(value): return INVALID_DATA_MODEL
    if spec["const_value"] is not None and spec["const_value"] != value: return CONST_MISMATCH
    if spec["enum_values"] is not None and value not in spec["enum_values"]: return ENUM_MISMATCH
    failure = length_bounds_failure(profile, value, spec["lengths"])
    if failure is not None: return failure
    use = spec["format"]
    if use is None: return None
    if sum_tag(use) == "Named":
        binding = _named(profile.get("format_bindings", ()), payload(use))
        if binding is None: return None
        return None if format_accepts_fast(profile.get("grapheme_rules"), binding["rule"], value) else format_condition(payload(use))
    return None if format_accepts_fast(profile.get("grapheme_rules"), payload(use), value) else format_condition("inline")


def sealed_string_condition(profile, spec, value):
    if not unicode_valid(value): return INVALID_DATA_MODEL
    if spec["const_value"] is not None and spec["const_value"] != value: return CONST_MISMATCH
    if spec["enum_values"] is not None and value not in spec["enum_values"]: return ENUM_MISMATCH
    failure = length_bounds_failure(profile, value, spec["lengths"])
    if failure is not None: return failure
    use = spec["format"]
    if use is None: return None
    if sum_tag(use) == "Named":
        return None if named_format_accepts(profile, payload(use), value) else format_condition(payload(use))
    return None if format_accepts_fast(profile.get("grapheme_rules"), payload(use), value) else format_condition("inline")


def _base64_digit(alphabet, c):
    if "A" <= c <= "Z": return ord(c) - ord("A")
    if "a" <= c <= "z": return ord(c) - ord("a") + 26
    if "0" <= c <= "9": return ord(c) - ord("0") + 52
    name = sum_tag(alphabet)
    if name == "Standard": return {"+": 62, "/": 63}.get(c)
    if name == "UrlSafe": return {"-": 62, "_": 63}.get(c)
    return {"+": 62, "-": 62, "/": 63, "_": 63}.get(c)


def _base64_tail_bits(digits, remainder):
    if not digits: return True
    last = digits[-1]
    return not (remainder == 2 and last % 16 != 0 or remainder == 3 and last % 4 != 0)


def base64_length(policy, text):
    parts = text.split("=")
    body, padding = parts[0], len(parts) - 1
    if padding > 2 or any(part != "" for part in parts[1:]): return None
    digits = [_base64_digit(policy["alphabet"], c) for c in body]
    if any(digit is None for digit in digits): return None
    remainder = len(body) % 4
    if remainder == 1: return None
    if policy["strict_pad_bits"] and not _base64_tail_bits(digits, remainder): return None
    if padding > 0 and (len(text) % 4 != 0 or padding != (4 - remainder) % 4): return None
    if padding == 0 and not policy["padding_optional"] and remainder != 0: return None
    return len(body) // 4 * 3 + (0 if remainder == 0 else remainder - 1)


def wrapper_payload_text(profile, wrapper, value):
    key = wrapper["key"]
    if not isinstance(value, Mapping) or list(value) != [key] or type(value[key]) is not str: return None
    text = value[key]
    kind = wrapper["payload"]
    if sum_tag(kind) == "Bytes":
        policy = profile.get("bytes_policy")
        return text if policy is not None and base64_length(policy, text) is not None else None
    format_name = payload(kind)
    if format_name is None: return text if unicode_valid(text) else None
    return text if unicode_valid(text) and named_format_accepts(profile, format_name, text) else None


def wrapper_payload_failure(profile, wrapper, value):
    if wrapper_payload_text(profile, wrapper, value) is not None: return None
    kind = wrapper["payload"]
    if sum_tag(kind) == "Bytes": return INVALID_BYTES
    format_name = payload(kind)
    return wrong_value_kind("wrapper text") if format_name is None else format_condition(format_name)


def _text_wrapper(profile):
    return next((wrapper for wrapper in profile["wrappers"] if sum_tag(wrapper["payload"]) == "Text"), None)


def wrapper_text_accepts(profile, value):
    wrapper = _text_wrapper(profile)
    return wrapper is not None and wrapper_payload_text(profile, wrapper, value) is not None



def string_value_condition(profile, spec, value):
    wrapper_name = spec["wrapper"]
    if wrapper_name is None:
        return string_condition(profile, spec, value) if type(value) is str else wrong_value_kind("string")
    if not isinstance(value, Mapping): return wrong_value_kind("string wrapper")
    classification, wrapper = classOf(profile, value)
    if classification != "Wrapper" or wrapper["name"] != wrapper_name: return wrong_value_kind("string wrapper")
    text = wrapper_payload_text(profile, wrapper, value)
    if text is None: return wrapper_payload_failure(profile, wrapper, value)
    return string_condition(profile, spec, text)


def bytes_value_length(profile, value):
    policy = profile.get("bytes_policy")
    if policy is None: return None
    wrapper_name = policy.get("wrapper")
    if wrapper_name is None:
        text = value if type(value) is str else None
    else:
        wrapper = _named(profile.get("wrappers", ()), wrapper_name)
        text = None if wrapper is None else wrapper_payload_text(profile, wrapper, value)
    return None if text is None else base64_length(policy, text)


def _decimal_text(value):
    return value.spelling if isinstance(value, DecimalLiteral) else str(value)


_JSON_NUMBER = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")


def json_number_text_admitted(text):
    return _JSON_NUMBER.fullmatch(text) is not None and not json_text_exponent_too_large(text)


def decimal_integer_parts(text):
    if text.strip(" \t\n\r") != text or text.startswith("+") or not json_number_text_admitted(text): return None
    number = Decimal(text)
    return number if number.is_finite() and number == number.to_integral_value() else None


def decimal_integer(text):
    number = decimal_integer_parts(text)
    return None if number is None else int(number)


def integer_binding(profile, domain):
    return _named(profile.get("integer_domains", ()), domain if domain is not None else profile.get("default_integer_domain"))


def integer_value_for_form(form, value):
    name = sum_tag(form)
    if name == "Number": return value if type(value) is int else None
    if name == "IntegralDecimal": return decimal_integer(_decimal_text(value)) if isinstance(value, (float, DecimalLiteral, Decimal)) else None
    if name == "DecimalString": return decimal_integer(value) if type(value) is str else None
    return None


def integer_value_for_binding(binding, value):
    for form in binding.get("forms", ()):
        result = integer_value_for_form(form, value)
        if result is not None: return result
    return None


def integer_value_for_domain(profile, domain, value):
    binding = integer_binding(profile, domain)
    return None if binding is None else integer_value_for_binding(binding, value)


def decode_optional(decoder, value):
    return None if value is None else decoder(value)


def encode_optional(encoder, value):
    return None if value is None else encoder(value)


def integer_range_accepts(domain, value):
    if sum_tag(domain) != "Inclusive": return True
    bounds = payload(domain)
    return integer(bounds["minimum"]) <= value <= integer(bounds["maximum"])


def _json_digit(character):
    return "0" <= character <= "9"


def _json_whole_number(text):
    return text == "0" or (text != "" and "1" <= text[0] <= "9" and all(_json_digit(c) for c in text[1:]))


def _exponent_exceeds(digits, bound):
    if bound < 0: return True
    significant = digits.lstrip("0") or "0"
    limit = str(bound)
    return len(significant) > len(limit) or (len(significant) == len(limit) and significant > limit)


def decimal_magnitude_exceeds_range_digits(minimum, maximum, text):
    unsigned = text[1:] if text.startswith("-") else text
    if unsigned.startswith("+"): return False
    parts = unsigned.split("e")
    if len(parts) != 2: parts = unsigned.split("E")
    if len(parts) != 2: return False
    base, exponent_text = parts
    exponent_digits = exponent_text[1:] if exponent_text.startswith("+") else exponent_text
    if exponent_digits == "" or not (exponent_digits.isascii() and exponent_digits.isdigit()): return False
    limit_length = len(str(max(abs(minimum), abs(maximum))))
    pieces = base.split(".")
    if len(pieces) == 1:
        if not _json_whole_number(pieces[0]): return False
        significant = len(pieces[0].lstrip("0"))
        return significant != 0 and _exponent_exceeds(exponent_digits, limit_length - significant)
    if len(pieces) == 2:
        whole, fraction = pieces
        if not _json_whole_number(whole) or fraction == "" or not (fraction.isascii() and fraction.isdigit()) or not _exponent_exceeds(exponent_digits, len(fraction) - 1): return False
        significant = len((whole + fraction).lstrip("0"))
        return significant != 0 and _exponent_exceeds(exponent_digits, limit_length + len(fraction) - significant)
    return False


def integer_value_for_binding_in_range(binding, value):
    domain = binding.get("range", {"tag": "Unbounded"})
    if sum_tag(domain) != "Inclusive":
        result = integer_value_for_binding(binding, value)
        return None if result is None else (result,)
    bounds = payload(domain)
    minimum, maximum = integer(bounds["minimum"]), integer(bounds["maximum"])
    forms = {sum_tag(form) for form in binding.get("forms", ())}
    exceeds = (
        isinstance(value, (float, DecimalLiteral, Decimal)) and "IntegralDecimal" in forms and decimal_magnitude_exceeds_range_digits(minimum, maximum, _decimal_text(value))
    ) or (type(value) is str and "DecimalString" in forms and decimal_magnitude_exceeds_range_digits(minimum, maximum, value))
    if exceeds: return (None,)
    result = integer_value_for_binding(binding, value)
    if result is None: return None
    return (result,) if integer_range_accepts(domain, result) else (None,)


def integer_in_domain(profile, domain, value):
    binding = integer_binding(profile, domain)
    if binding is None: return False
    result = integer_value_for_binding_in_range(binding, value)
    return result is not None and result[0] is not None


def integer_condition(profile, spec, value):
    binding = integer_binding(profile, spec.get("domain"))
    if binding is None: return INTEGER_DOMAIN
    result = integer_value_for_binding_in_range(binding, value)
    if result is None: return wrong_value_kind("integer")
    parsed = result[0]
    if parsed is None: return INTEGER_DOMAIN
    if spec.get("const_value") is not None and integer(spec["const_value"]) != parsed: return CONST_MISMATCH
    if spec.get("enum_values") is not None and parsed not in [integer(item) for item in spec["enum_values"]]: return ENUM_MISMATCH
    if spec.get("minimum") is not None and parsed < integer(spec["minimum"]): return BELOW_MINIMUM
    if spec.get("maximum") is not None and parsed > integer(spec["maximum"]): return ABOVE_MAXIMUM
    return None


def tag_member_failure(profile, members):
    model = profile.get("tag")
    if model is None or model["key"] not in members: return None
    key, tag = model["key"], members[model["key"]]
    if type(tag) is not str: return (key, INVALID_TAG, tag)
    if not unicode_valid(tag): return (key, INVALID_DATA_MODEL, tag)
    if model["format"] is None or named_format_accepts(profile, model["format"], tag): return None
    return (key, INVALID_TAG, tag)


def duplicate_key(members):
    seen = set()
    for name, _ in members.items():
        if name in seen: return name
        seen.add(name)
    return None


def members_in_stored_order(members):
    return tuple(members.items())


def object_member_failure(profile, members):
    key = duplicate_key(members)
    if key is not None: return ((), duplicate_field(key), members)
    failure = tag_member_failure(profile, members)
    return None if failure is None else ((_step(failure[0]),), failure[1], failure[2])


def sealed_integer_condition(profile, spec, value):
    return integer_condition(profile, spec, value)


def sealed_leaf_failure(profile, leaf, value):
    kind, spec = sum_tag(leaf), payload(leaf)
    if kind == "String":
        if type(value) is str: return sealed_string_condition(profile, spec, value)
        if isinstance(value, Mapping):
            classification, wrapper = classOf(profile, value)
            if classification != "Wrapper": return wrong_value_kind("string")
            text = wrapper_payload_text(profile, wrapper, value)
            return wrapper_payload_failure(profile, wrapper, value) if text is None else sealed_string_condition(profile, spec, text)
        return wrong_value_kind("string")
    if type(value) is int: return sealed_integer_condition(profile, spec, value)
    return wrong_value_kind("integer")


def sealed_field_failure(profile, members, field):
    if field["key"] not in members:
        return (field["key"], MISSING_REQUIRED, None) if field["required"] else None
    condition = sealed_leaf_failure(profile, field["leaf"], members[field["key"]])
    return None if condition is None else (field["key"], condition, members[field["key"]])


def sealed_fields_failure(profile, form, members):
    for field in form["fields"]:
        failure = sealed_field_failure(profile, members, field)
        if failure is not None: return failure
    return None


def sealed_known_field(tag, form, key):
    return key == tag["key"] or any(field["key"] == key for field in form["fields"])


def sealed_refinement_failure(profile, members, refinements):
    for refinement in refinements:
        if refinement["key"] in members:
            condition = sealed_leaf_failure(profile, refinement["leaf"], members[refinement["key"]])
            if condition is not None: return (refinement["key"], condition, members[refinement["key"]])
    return None


def data_value_failure(profile, path, value):
    return _run_trampoline(_data_value_steps(profile, path, value))


def _data_value_steps(profile, path, value):
    if type(value) is int:
        return None if integer_in_domain(profile, None, value) else (path, INTEGER_DOMAIN, value)
    if isinstance(value, (float, DecimalLiteral, Decimal)):
        text = _decimal_text(value)
        if not json_number_text_admitted(text): return (path, INVALID_DATA_MODEL, value)
        binding = integer_binding(profile, None)
        integral_unbounded = (
            binding is not None
            and sum_tag(binding.get("range", {"tag": "Unbounded"})) == "Unbounded"
            and "IntegralDecimal" in {sum_tag(form) for form in binding.get("forms", ())}
            and decimal_integer_parts(text) is not None
        )
        if integral_unbounded: return None
        condition = integer_condition(profile, {}, value)
        if condition is None: return None
        if condition == INTEGER_DOMAIN: return (path, INTEGER_DOMAIN, value)
        return None if profile.get("numbers", {}).get("decimals", False) else (path, INVALID_DATA_MODEL, value)
    if type(value) is str:
        return None if unicode_valid(value) else (path, INVALID_DATA_MODEL, value)
    if isinstance(value, list):
        return (yield _data_items_steps(profile, path, 0, value))
    if isinstance(value, Mapping):
        failure = object_member_failure(profile, value)
        if failure is not None: return ((*path, *(_step(item) for item in failure[0])), failure[1], failure[2])
        classification, declaration = classOf(profile, value)
        if classification == "Wrapper":
            condition = wrapper_payload_failure(profile, declaration, value)
            return None if condition is None else (path, condition, value)
        if classification == "Sealed":
            failure = sealed_fields_failure(profile, declaration, value)
            if failure is not None: return ((*path, _step(failure[0])), failure[1], failure[2])
            return (yield _sealed_extras_steps(profile, path, declaration, value))
        return (yield _data_members_steps(profile, path, members_in_stored_order(value)))
    return None


def _data_items_steps(profile, path, index, items):
    for offset, item in enumerate(items):
        failure = yield _data_value_steps(profile, (*path, _step(index + offset)), item)
        if failure is not None: return failure
    return None


def _data_members_steps(profile, path, members):
    for key, value in members:
        if not unicode_valid(key): return ((*path, _step(key)), INVALID_DATA_MODEL, value)
        failure = yield _data_value_steps(profile, (*path, _step(key)), value)
        if failure is not None: return failure
    return None


def _data_sealed_members_steps(profile, path, tag, form, members):
    for key, value in members:
        if sealed_known_field(tag, form, key): continue
        if sum_tag(form["extras"]) == "Reject": return ((*path, _step(key)), unexpected_field(key), value)
        if not unicode_valid(key): return ((*path, _step(key)), INVALID_DATA_MODEL, value)
        failure = yield _data_value_steps(profile, (*path, _step(key)), value)
        if failure is not None: return failure
    return None


def sealed_extras_failure(profile, path, form, members):
    return _run_trampoline(_sealed_extras_steps(profile, path, form, members))


def _sealed_extras_steps(profile, path, form, members):
    tag = profile.get("tag")
    if tag is None: return (path, INVALID_DATA_MODEL, members)
    return (yield _data_sealed_members_steps(profile, path, tag, form, members_in_stored_order(members)))


def compare_decimal_bound(text, bound):
    value = Decimal(text)
    target = Decimal(f"{integer(bound['mantissa'])}E{-integer(bound['scale'])}")
    return (value > target) - (value < target)


def decimal_condition(spec, text):
    if not json_number_text_admitted(text): return INVALID_DATA_MODEL
    minimum, maximum = spec["minimum"], spec["maximum"]
    ordering = None if minimum is None else compare_decimal_bound(text, minimum)
    if ordering is not None and (ordering < 0 or ordering == 0 and minimum["exclusive"]): return BELOW_MINIMUM
    ordering = None if maximum is None else compare_decimal_bound(text, maximum)
    if ordering is not None and ordering > 0: return ABOVE_MAXIMUM
    if ordering == 0 and maximum["exclusive"]: return ABOVE_MAXIMUM
    return None


def _ascii_lower(text):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in text)


def _ascii_alpha(c): return "A" <= c <= "Z" or "a" <= c <= "z"
def _ascii_digit(c): return "0" <= c <= "9"
def _ascii_alnum(c): return _ascii_alpha(c) or _ascii_digit(c)
def _ascii_hex(c): return _ascii_digit(c) or "a" <= c <= "f" or "A" <= c <= "F"
def _ascii(text): return all(ord(c) < 128 for c in text)
def _all_chars(test, text): return all(test(c) for c in text)
def _nonempty_chars(test, text): return text != "" and _all_chars(test, text)


def _split_char(delimiter, chars):
    if delimiter in chars:
        index = chars.index(delimiter)
        return chars[:index], chars[index + 1:]
    return chars, None


def _uri_unreserved(c): return _ascii_alnum(c) or c in "-._~"
def _uri_subdelim(c): return c in "!$&'()*+,;="


def _uri_chars(extra, chars):
    index = 0
    while index < len(chars):
        c = chars[index]
        if c == "%":
            if index + 2 < len(chars) and _ascii_hex(chars[index + 1]) and _ascii_hex(chars[index + 2]):
                index += 3
                continue
            return False
        if not (_uri_unreserved(c) or _uri_subdelim(c) or extra(c)):
            return False
        index += 1
    return True


def _ipv4(text):
    parts = text.split(".")
    return len(parts) == 4 and all(
        _nonempty_chars(_ascii_digit, part) and len(part) <= 3 and (part == "0" or not part.startswith("0")) and int(part) <= 255
        for part in parts
    )


def _ipv6_group_count(parts):
    if not parts: return 0
    if len(parts) == 1:
        last = parts[0]
        if "." in last: return 2 if _ipv4(last) else None
        return 1 if last != "" and len(last) <= 4 and _all_chars(_ascii_hex, last) else None
    part = parts[0]
    if part == "" or len(part) > 4 or not _all_chars(_ascii_hex, part): return None
    rest = _ipv6_group_count(parts[1:])
    return None if rest is None else 1 + rest


def _ipv6(text):
    pieces = text.split("::")
    if len(pieces) == 1:
        return _ipv6_group_count(pieces[0].split(":")) == 8
    if len(pieces) == 2:
        before, after = pieces
        left = 0 if before == "" else _ipv6_group_count(before.split(":"))
        right = 0 if after == "" else _ipv6_group_count(after.split(":"))
        return left is not None and right is not None and left + right < 8 and "." not in before
    return False


def _ip_literal(text):
    if text.startswith("v") or text.startswith("V"):
        version, *tail = text.split(".")
        return _nonempty_chars(_ascii_hex, version[1:]) and _nonempty_chars(
            lambda c: _uri_unreserved(c) or _uri_subdelim(c) or c == ":", ".".join(tail)
        )
    return _ipv6(text)


def _uri_host_port(chars):
    if chars[:1] == ["["]:
        host, after = _split_char("]", chars[1:])
        if not _ip_literal("".join(host)): return False
        if after is None: return False
        if after == []: return True
        return after[0] == ":" and all(_ascii_digit(c) for c in after[1:])
    host, port = _split_char(":", chars)
    return _uri_chars(lambda _: False, host) and (port is None or all(_ascii_digit(c) for c in port))


def _uri_authority(chars):
    before, after = _split_char("@", chars)
    if after is None: return _uri_host_port(before)
    return _uri_chars(lambda c: c == ":", before) and "@" not in after and _uri_host_port(after)


def _uri_syntax(text):
    scheme, tail = _split_char(":", list(text))
    scheme_ok = bool(scheme) and _ascii_alpha(scheme[0]) and all(_ascii_alnum(c) or c in "+-." for c in scheme[1:])
    if not scheme_ok or tail is None: return False
    before_fragment, fragment = _split_char("#", tail)
    hierarchy, query = _split_char("?", before_fragment)
    path_extra = lambda c: c in ":@/"
    query_extra = lambda c: c in ":@/?"
    if hierarchy[:2] == ["/", "/"]:
        rest = hierarchy[2:]
        authority = rest[:rest.index("/")] if "/" in rest else rest
        path_ok = _uri_authority(authority) and _uri_chars(path_extra, rest[len(authority):])
    else:
        path_ok = _uri_chars(path_extra, hierarchy)
    return path_ok and (query is None or _uri_chars(query_extra, query)) and (fragment is None or _uri_chars(query_extra, fragment))


def _language_subtag(minimum, maximum, text):
    return minimum <= len(text) <= maximum and _all_chars(_ascii_alnum, text)


def _language_extensions(seen, parts):
    if not parts: return True
    if parts[0] == "x": return len(parts) > 1 and all(_language_subtag(1, 8, part) for part in parts[1:])
    singleton, rest = parts[0], parts[1:]
    if len(singleton) != 1 or not _all_chars(_ascii_alnum, singleton) or singleton in seen: return False
    count = 0
    while count < len(rest) and _language_subtag(2, 8, rest[count]): count += 1
    return count > 0 and _language_extensions([singleton, *seen], rest[count:])


def _language_variants(seen, parts):
    if not parts: return True
    part = parts[0]
    is_variant = _language_subtag(5, 8, part) or (len(part) == 4 and _all_chars(_ascii_alnum, part) and _ascii_digit(part[0]))
    if is_variant: return part not in seen and _language_variants([part, *seen], parts[1:])
    return _language_extensions([], parts)


def _language_syntax(grandfathered, text):
    lower = _ascii_lower(text)
    if not _ascii(text): return False
    if any(_ascii_lower(entry) == lower for entry in grandfathered): return True
    primary, *rest = lower.split("-")
    if primary == "x": return len(rest) > 0 and all(_language_subtag(1, 8, part) for part in rest)
    if not _all_chars(_ascii_alpha, primary) or len(primary) < 2 or len(primary) > 8: return False
    extended = 0
    if len(primary) <= 3:
        while extended < min(3, len(rest)) and len(rest[extended]) == 3 and _all_chars(_ascii_alpha, rest[extended]): extended += 1
    after_extended = rest[extended:]
    after_script = after_extended
    if after_extended and len(after_extended[0]) == 4 and _all_chars(_ascii_alpha, after_extended[0]): after_script = after_extended[1:]
    after_region = after_script
    if after_script and (
        len(after_script[0]) == 2 and _all_chars(_ascii_alpha, after_script[0])
        or len(after_script[0]) == 3 and _all_chars(_ascii_digit, after_script[0])
    ): after_region = after_script[1:]
    return _language_variants([], after_region)


def _digits_nat(chars):
    return int("".join(chars)) if chars and all(_ascii_digit(c) for c in chars) else None


def _leap_year(year): return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def _month_days(year, month):
    if month == 2: return 29 if _leap_year(year) else 28
    return 30 if month in (4, 6, 9, 11) else 31


def _timestamp_syntax(rule, text):
    chars = list(text)
    if len(chars) < 20: return False
    if (chars[4], chars[7], chars[10], chars[13], chars[16]) != ("-", "-", "T", ":", ":"): return False
    year, month, day = _digits_nat(chars[:4]), _digits_nat(chars[5:7]), _digits_nat(chars[8:10])
    hour, minute, second = _digits_nat(chars[11:13]), _digits_nat(chars[14:16]), _digits_nat(chars[17:19])
    if None in (year, month, day, hour, minute, second): return False
    if (year < integer(rule["minimum_year"]) or year > integer(rule["maximum_year"]) or month < 1 or month > 12
            or day < 1 or day > _month_days(year, month) or hour > 23 or minute > 59
            or second > (60 if rule["allow_second_60"] else 59)): return False
    suffix = chars[19:]
    timezone = suffix
    if suffix[:1] == ["."]:
        rest = suffix[1:]
        count = 0
        while count < len(rest) and _ascii_digit(rest[count]): count += 1
        timezone = [] if count == 0 else rest[count:]
    if timezone == ["Z"]: return True
    if len(timezone) == 6 and timezone[3] == ":":
        sign, h1, h2, _, m1, m2 = timezone
        if sign not in "+-": return False
        offset_hour, offset_minute = _digits_nat([h1, h2]), _digits_nat([m1, m2])
        if offset_hour is None or offset_minute is None: return False
        if offset_hour > 23 or offset_minute > 59 or (sign == "-" and offset_hour == 0 and offset_minute == 0): return False
        if rule["rejectUtcYearOutsideRange"]:
            preceding = sum(_month_days(year, index + 1) for index in range(month - 1))
            local = (preceding + day - 1) * 1440 + hour * 60 + minute
            offset = offset_hour * 60 + offset_minute
            utc = local - offset if sign == "+" else local + offset
            year_minutes = (366 if _leap_year(year) else 365) * 1440
            if year == integer(rule["minimum_year"]) and utc < 0: return False
            if year == integer(rule["maximum_year"]) and utc >= year_minutes: return False
        return True
    return False


def _dfa_accepts(spec, text):
    state = integer(spec["initial_state"])
    for c in text:
        if ord(c) >= 128: return False
        transition = next((row for row in spec["transitions"] if integer(row["from_state"]) == state and integer(row["first"]) <= ord(c) <= integer(row["last"])), None)
        if transition is None: return False
        state = integer(transition["to_state"])
    return state in [integer(item) for item in spec["accepting_states"]]


def format_length(grapheme_rules, unit, text):
    name = sum_tag(unit)
    if name == "Utf8Bytes": return utf8_length(text)
    if name == "UnicodeScalars": return len(text)
    if name == "Graphemes": return None if grapheme_rules is None else grapheme_length(grapheme_rules, text)
    return None


def label_parts(separator, text):
    return text.split(separator) if separator else [text]


def format_rule_depth(rule):
    kind, spec = sum_tag(rule), payload(rule)
    if kind in ("Sequence", "Choice"): return 1 + format_rules_depth(spec)
    if kind in ("Optional", "Not"): return 1 + format_rule_depth(spec)
    if kind in ("Labels", "Bounded"): return 1 + format_rule_depth(spec["rule"])
    return 1


def format_rules_depth(rules):
    return max((format_rule_depth(child) for child in rules), default=0)


def _char_splits(chars):
    return ((chars[:split], chars[split:]) for split in range(len(chars) + 1))


def _string_splits(text):
    return _char_splits(text)


def _sequence_accepts_with(accepts, parts, text):
    if not parts: return text == ""
    return any(accepts(parts[0], head) and _sequence_accepts_with(accepts, parts[1:], rest) for head, rest in _string_splits(text))


def _format_within(grapheme_rules, unit, maximum, text):
    length = format_length(grapheme_rules, unit, text)
    return length is not None and length <= integer(maximum)


def format_accepts_fuel(grapheme_rules, fuel, rule, text):
    if fuel == 0: return False
    kind, spec = sum_tag(rule), payload(rule)
    if kind == "Literal": return spec == text
    if kind == "Sequence": return _sequence_accepts_with(lambda part, piece: format_accepts_fuel(grapheme_rules, fuel - 1, part, piece), spec, text)
    if kind == "Optional": return format_accepts_fuel(grapheme_rules, fuel - 1, spec, text) or text == ""
    if kind == "Labels":
        values = label_parts(spec["separator"], text)
        return (spec["separator"] != "" and len(values) >= integer(spec["min_count"])
                and (spec["max_count"] is None or len(values) <= integer(spec["max_count"]))
                and (spec["total_max"] is None or len(text) <= integer(spec["total_max"]))
                and all(format_accepts_fuel(grapheme_rules, fuel - 1, spec["rule"], value) for value in values))
    if kind == "Bounded":
        return _format_within(grapheme_rules, spec["unit"], spec["maximum"], text) and format_accepts_fuel(grapheme_rules, fuel - 1, spec["rule"], text)
    if kind == "AsciiDfa": return _dfa_accepts(spec, text)
    if kind == "Identifier":
        return (_ascii(text) and integer(spec["min_length"]) <= len(text)
                and (spec["max_length"] is None or len(text) <= integer(spec["max_length"]))
                and (spec["exact_length"] is None or integer(spec["exact_length"]) == len(text))
                and text not in spec["forbidden"]
                and text != "" and text[0] in spec["first_alphabet"] and all(c in spec["rest_alphabet"] for c in text[1:]))
    if kind == "Timestamp": return _timestamp_syntax(spec, text)
    if kind == "AbsoluteUri": return (spec["max_bytes"] is None or utf8_length(text) <= integer(spec["max_bytes"])) and _uri_syntax(text)
    if kind == "LanguageTag": return _language_syntax(spec["grandfathered"], text)
    if kind == "Choice": return any(format_accepts_fuel(grapheme_rules, fuel - 1, child, text) for child in spec)
    if kind == "Text": return True
    if kind == "Not": return format_rule_depth(spec) <= fuel - 1 and not format_accepts_fuel(grapheme_rules, fuel - 1, spec, text)
    return False


def format_accepts(grapheme_rules, rule, text):
    return format_accepts_fuel(grapheme_rules, format_rule_depth(rule), rule, text)


@dataclass(frozen=True, slots=True)
class _SpanNode:
    id: int
    kind: str
    rule: object = None
    children: tuple = ()


def _span_size(node):
    if node.kind in ("Epsilon", "Literal", "Text", "Leaf"): return 1
    if node.kind == "Sequence": return _span_size(node.children[0]) + _span_size(node.children[1]) + 1
    return 1 + sum(_span_size(child) for child in node.children)


def _fresh_format_span_id(counter):
    counter[0] += 1
    return counter[0] - 1


def _binary_format_sequence(counter, nodes):
    if not nodes: return _SpanNode(_fresh_format_span_id(counter), "Epsilon")
    if len(nodes) == 1: return nodes[0]
    right = _binary_format_sequence(counter, nodes[1:])
    return _SpanNode(_fresh_format_span_id(counter), "Sequence", None, (nodes[0], right))


def _compile_format_span(counter, fuel, rule):
    if fuel == 0: return _SpanNode(_fresh_format_span_id(counter), "Leaf", rule)
    kind, spec = sum_tag(rule), payload(rule)
    if kind == "Literal": return _SpanNode(_fresh_format_span_id(counter), "Literal", spec)
    if kind == "Text": return _SpanNode(_fresh_format_span_id(counter), "Text")
    if kind in ("Not", "Optional"):
        node_id = _fresh_format_span_id(counter)
        return _SpanNode(node_id, kind, None, (_compile_format_span(counter, fuel - 1, spec),))
    if kind == "Choice":
        node_id = _fresh_format_span_id(counter)
        return _SpanNode(node_id, "Choice", None, tuple(_compile_format_span(counter, fuel - 1, child) for child in spec))
    if kind == "Sequence":
        return _binary_format_sequence(counter, [_compile_format_span(counter, fuel - 1, child) for child in spec])
    if kind in ("Labels", "Bounded"):
        node_id = _fresh_format_span_id(counter)
        return _SpanNode(node_id, kind, spec, (_compile_format_span(counter, fuel - 1, spec["rule"]),))
    return _SpanNode(_fresh_format_span_id(counter), "Leaf", rule)


def _format_span_literal(source, value, start, finish):
    return source[start:finish] == value


def _format_span_split_points(start, finish):
    return range(start, finish + 1)


def _format_span_and(left, right):
    return left() and right()


def _format_span_short_circuit(target, check, items):
    for item in items:
        if check(item) == target: return target
    return not target


def _eval_format_span(grapheme_rules, fuel, source, node, start, finish, memo):
    if fuel == 0: return False
    key = (node.id, start, finish, source)
    if key in memo: return memo[key]
    kind = node.kind
    if kind == "Not": return not _eval_format_span(grapheme_rules, fuel - 1, source, node.children[0], start, finish, memo)
    if kind == "Labels":
        spec = node.rule
        if not spec["separator"]: return False
        pieces = label_parts(spec["separator"], source[start:finish])
        if len(pieces) < integer(spec["min_count"]): return False
        if spec["max_count"] is not None and len(pieces) > integer(spec["max_count"]): return False
        if spec["total_max"] is not None and finish - start > integer(spec["total_max"]): return False
        accepted = _format_span_short_circuit(False, lambda piece: _eval_format_span(grapheme_rules, fuel - 1, piece, node.children[0], 0, len(piece), memo), pieces)
    elif kind == "Epsilon": accepted = start == finish
    elif kind == "Literal": accepted = _format_span_literal(source, node.rule, start, finish)
    elif kind == "Text": accepted = True
    elif kind == "Choice":
        accepted = _format_span_short_circuit(True, lambda child: _eval_format_span(grapheme_rules, fuel - 1, source, child, start, finish, memo), node.children)
    elif kind == "Sequence":
        accepted = _format_span_short_circuit(
            True,
            lambda split: _format_span_and(
                lambda: _eval_format_span(grapheme_rules, fuel - 1, source, node.children[0], start, split, memo),
                lambda: _eval_format_span(grapheme_rules, fuel - 1, source, node.children[1], split, finish, memo),
            ),
            _format_span_split_points(start, finish),
        )
    elif kind == "Optional":
        accepted = start == finish or _eval_format_span(grapheme_rules, fuel - 1, source, node.children[0], start, finish, memo)
    elif kind == "Bounded":
        accepted = _format_within(grapheme_rules, node.rule["unit"], node.rule["maximum"], source[start:finish]) and _eval_format_span(grapheme_rules, fuel - 1, source, node.children[0], start, finish, memo)
    else:
        accepted = format_accepts(grapheme_rules, node.rule, source[start:finish])
    memo[key] = accepted
    return accepted


def format_accepts_fast(grapheme_rules, rule, text):
    node = _compile_format_span([0], format_rule_depth(rule), rule)
    size = _span_size(node)
    limit = sys.getrecursionlimit()
    sys.setrecursionlimit(max(limit, 8 * size + 1000))
    try:
        return _eval_format_span(grapheme_rules, size, text, node, 0, len(text), {})
    finally:
        sys.setrecursionlimit(limit)


def classOf(profile, members):
    if isinstance(members, Mapping): members = list(members.items())
    values = {}
    for key, value in members:
        values.setdefault(key, value)
    model = profile.get("tag")
    if model is not None and type(values.get(model["key"])) is str:
        form = next((form for form in model["sealed"] if form["tag"] == values[model["key"]]), None)
        if form is not None: return ("Sealed", form)
    wrapper = next((item for item in profile.get("wrappers", ()) if item["key"] in values), None)
    return ("Wrapper", wrapper) if wrapper is not None else ("Ordinary", None)


def member_test_matches(profile, members, test):
    check = test["test"]
    if sum_tag(check) == "Absent": return test["key"] not in members
    if test["key"] not in members or type(members[test["key"]]) is not str: return False
    return named_format_accepts(profile, payload(check), members[test["key"]])


def _value_kind_matches(expected, value):
    actual = "Null" if value is None else "Boolean" if type(value) is bool else "Number" if isinstance(value, (int, DecimalLiteral, Decimal)) else "String" if type(value) is str else "Array" if isinstance(value, list) else "Object" if isinstance(value, Mapping) else "Unknown"
    return actual == expected


def _selector_matches(profile, branch, value):
    selector = branch["selector"]
    kind = sum_tag(selector)
    if kind == "InternalTag":
        model = profile.get("tag")
        return model is not None and isinstance(value, Mapping) and value.get(model["key"]) == branch["wire_tag"]
    if kind == "MemberShape" and isinstance(value, Mapping):
        return all(member_test_matches(profile, value, test) for test in payload(selector))
    if kind == "Kind":
        return _value_kind_matches(sum_tag(payload(selector)), value)
    return kind == "Otherwise"


def select_union_branch(profile, branches, value):
    for branch in branches:
        if _selector_matches(profile, branch, value): return branch
    return None


def _value_json(value):
    return _convert_tree(value, (list, tuple), lambda item: item)


def _convert_tree(value, sequence_types, leaf, *, sorted_keys=False):
    def members(item):
        pairs = list(item.items())
        return sorted(pairs, key=lambda pair: pair[0]) if sorted_keys else pairs

    def children(item):
        if isinstance(item, Mapping): return [child for _, child in members(item)]
        if isinstance(item, sequence_types): return item
        return None

    def build(item, results):
        if isinstance(item, Mapping): return JsonObject((key, result) for (key, _), result in zip(members(item), results))
        return list(results)

    return _rebuild(value, children, leaf, build)


def _run_trampoline(steps):
    stack, result = [steps], None
    while stack:
        try:
            request = stack[-1].send(result)
        except StopIteration as stop:
            stack.pop()
            result = stop.value
        else:
            stack.append(request)
            result = None
    return result


@dataclass(frozen=True, slots=True)
class FieldStep:
    value: str


@dataclass(frozen=True, slots=True)
class IndexStep:
    value: int

    def __post_init__(self) -> None:
        if self.value < 0:
            raise ValueError(f"value must not be negative: {self.value}")


@dataclass(frozen=True, slots=True)
class VariantStep:
    value: str


PathStep: TypeAlias = FieldStep | IndexStep | VariantStep
ValuePath: TypeAlias = tuple[PathStep, ...]


def _step(value):
    if isinstance(value, (FieldStep, IndexStep, VariantStep)):
        return value
    return IndexStep(value) if isinstance(value, int) else FieldStep(value)


def path_step_json(step):
    if isinstance(step, VariantStep):
        return "variant:" + step.value
    return step.value


def path_steps_json(path):
    return [path_step_json(step) for step in path]


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


def _json_size(value):
    size, pending = 0, [value]
    while pending:
        item = pending.pop()
        size += 1
        if isinstance(item, list):
            pending.extend(item)
        elif isinstance(item, Mapping):
            pending.extend(child for _, child in item.items())
    return size


@dataclass(frozen=True, slots=True)
class ValueRequirement:
    type_ref: object
    value_path: tuple
    value: object
    link: object = dataclass_field(default=None, compare=False)


@dataclass(frozen=True, slots=True)
class ExpansionRequirements:
    children: tuple = ()


@dataclass(frozen=True, slots=True)
class ExpansionRejected:
    failure: ValueFailure


@dataclass(frozen=True, slots=True)
class ExpansionUnresolved:
    obligations: tuple


@dataclass(frozen=True, slots=True)
class MemberProof:
    children: tuple


@dataclass(frozen=True, slots=True)
class MemberCertificate:
    profile: object
    source_refs: tuple
    contract: object
    value: object
    proof: MemberProof | None


@dataclass(frozen=True, slots=True)
class ValidationValueFailure:
    failure: ValueFailure


@dataclass(frozen=True, slots=True)
class ValidationUnresolved:
    obligations: tuple


@dataclass(frozen=True, slots=True)
class ValidationCertificateMismatch:
    condition: str


ValidationFailure: TypeAlias = ValidationValueFailure | ValidationUnresolved | ValidationCertificateMismatch


@dataclass(frozen=True, slots=True)
class MembershipAccepted:
    proof: MemberProof


@dataclass(frozen=True, slots=True)
class MembershipRejected:
    failure: ValueFailure


@dataclass(frozen=True, slots=True)
class MembershipUnresolved:
    obligations: tuple


@dataclass(frozen=True, slots=True)
class MembershipInvalidCertificate:
    condition: str


_validated_value_token = object()


@dataclass(frozen=True, slots=True, init=False)
class ValidatedValue:
    proof: MemberProof

    def __init__(self, token: object, proof: MemberProof) -> None:
        if token is not _validated_value_token:
            raise TypeError("validated value requires validation")
        object.__setattr__(self, "proof", proof)


def _extra_children(extras):
    return [payload(extras)["value"]["type_ref"]] if sum_tag(extras) == "Allow" else []


def _trail_holds(trail, key, depth):
    while trail is not None:
        _, held, at, trail = trail
        if at != depth: return False
        if held == key: return True
    return False


def _trail_references(trail):
    references = []
    while trail is not None:
        reference, _, _, trail = trail
        references.append(reference)
    return tuple(references)


class ValueContext:

    def __init__(self, graph):
        self.graph = graph
        self.profile = prepare_profile(graph["profile"])
        self.nodes = {}
        self.references = {}
        self._resolved = {}
        for node in graph.get("nodes", ()):
            reference = node["reference"]
            key = ref_key(reference)
            self.nodes.setdefault(key, node)
            if "id" in node:
                identity = ref_key(node["id"])
                self.references.setdefault(identity, reference)
                self._resolved.setdefault(identity, (reference, key))
        self._links = {}
        self._faulty = set()
        for key, node in self.nodes.items():
            try:
                self._links[key] = tuple(self._link(child) for child in self._node_children(node))
            except Exception:
                self._links[key] = ()
                self._faulty.add(key)
        self._edges = sum(len(links) for links in self._links.values())
        self._blocked = self._meaning_table()

    def _link(self, reference):
        key = ref_key(reference)
        return self._resolved.get(key) or (reference, key)

    def _resolve(self, reference):
        key = ref_key(reference)
        return self._resolved.get(key) or (reference, key)

    def _meaning_table(self):
        parents = {}
        blocked = set(self._faulty)
        for key, links in self._links.items():
            try:
                if self._meaning_reasons(key):
                    blocked.add(key)
            except Exception:
                blocked.add(key)
            for _, child in links:
                if child in self.nodes:
                    parents.setdefault(child, []).append(key)
                else:
                    blocked.add(key)
        pending = list(blocked)
        while pending:
            for parent in parents.get(pending.pop(), ()):
                if parent not in blocked:
                    blocked.add(parent)
                    pending.append(parent)
        return {key: key in blocked for key in self.nodes}

    def meaning_remaining(self, reference):
        reference, key = self._resolve(reference)
        return self._obligations([(reference, key)]) if self._blocked.get(key, True) else []

    def reference(self, reference):
        return self._resolve(reference)[0]

    def shape(self, reference):
        reference, key = self._resolve(reference)
        node = self.nodes.get(key)
        if node is None: raise UnresolvedValueFailure(self._obligations([(reference, key)]))
        return node["shape"]


    def _meaning_reasons(self, key):
        node = self.nodes.get(key)
        if node is None:
            return [variant("UnresolvedType")]
        kind, spec = sum_tag(node["shape"]), payload(node["shape"])
        reasons = []
        if kind == "String":
            uses_graphemes = any(sum_tag(bound["unit"]) == "Graphemes" for bound in spec["lengths"]) or (
                spec["format"] is not None and format_use_uses_graphemes(self.profile, spec["format"]))
            if uses_graphemes and self.profile.get("grapheme_rules") is None:
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
            domain_name = spec["domain"] if spec["domain"] is not None else self.profile.get("default_integer_domain")
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

    def _node_children(self, node):
        kind, spec = sum_tag(node["shape"]), payload(node["shape"])
        if kind == "Product":
            allowed = _extra_children(spec["extras"])
            return [*(field["slot"]["type_ref"] for field in spec["fields"]), *allowed]
        if kind == "Array":
            return [spec["item"]["type_ref"]]
        if kind == "Alias":
            return [spec["target"]]
        if kind == "TaggedUnion":
            return [branch["target"] for branch in spec["branches"]]
        return []

    def _reachable_types(self, resolved):
        """Lean reachableTypes: the types reached from the references, in the order of the walk."""
        pending = deque(resolved)
        seen = set()
        reachable = []
        for _ in range(len(pending) + len(self.nodes) + self._edges + 1):
            if not pending:
                break
            current, key = pending.popleft()
            if key in seen:
                continue
            seen.add(key)
            if key in self._faulty: self._node_children(self.nodes[key])
            reachable.append((current, key))
            pending.extendleft(reversed(self._links.get(key, ())))
        reachable.reverse()
        return reachable

    def _obligations(self, resolved):
        return [{"type_ref": reference, "origin": {"source": reference["source"], "pointer": reference["pointer"]}, "value_path": (), "profile": self.profile["reference"], "reason": reason}
                for current, key in self._reachable_types(resolved) for reference in (declared_type_ref(current),) for reason in self._meaning_reasons(key)]

    def meaning_obligations(self, references):
        """Lean meaningObligations: the reasons of each type reached from the references."""
        return self._obligations([self._resolve(reference) for reference in references])

    def check_meaning(self, reference):
        """Lean checkMeaningDefined: the first obligation with a meaning predicate, in obligation order."""
        for obligation in self.meaning_obligations((reference,)):
            predicate = MEANING_PREDICATES.get(obligation["reason"]["tag"])
            if predicate is not None:
                raise MeaningFailure(obligation["type_ref"], predicate, obligation["value_path"])

    def _checked_materialization_value(self, reference, value):
        return self._checked_resolved(*self._resolve(reference), value)

    def _checked_resolved(self, reference, key, value):
        checked = self._validate_resolved(reference, key, _value_json(value), None)
        if isinstance(checked, ValidationValueFailure):
            raise checked.failure
        if isinstance(checked, ValidationUnresolved):
            raise UnresolvedValueFailure(checked.obligations)
        if isinstance(checked, ValidationCertificateMismatch):
            raise CertificateMismatchFailure(checked.condition)
        return value

    def validate(self, reference, value):
        return self._checked_materialization_value(reference, value)

    def failure_at(self, reference, path, value, condition, trace=()):
        observed = ABSENT_VALUE if condition == MISSING_REQUIRED else value
        return ValueFailure(reference, path, condition, observed, trace)

    def obligation_at(self, reference, path, reason):
        return {"type_ref": reference, "origin": {"source": reference["source"], "pointer": reference["pointer"]}, "value_path": tuple(path), "profile": self.profile["reference"], "reason": reason}

    def extra_members_failure(self, spec, members):
        model = self.profile.get("tag")
        names = {field["wire_name"] for field in spec["fields"]}
        for key, value in members_in_stored_order(members):
            if key in names or (model is not None and key == model["key"]): continue
            if sum_tag(spec["extras"]) == "Reject": return ((_step(key),), unexpected_field(key), value)
            details = payload(spec["extras"])
            if not unicode_valid(key): return ((_step(key),), INVALID_DATA_MODEL, value)
            if details["key_format"] is not None and not format_use_accepts(self.profile, details["key_format"], key): return ((_step(key),), key_format(key), value)
        return None

    def element_requirements(self, contract, path, value, link):
        if value is None and contract["nullable"]: return ()
        return (ValueRequirement(contract["type_ref"], path, value, link),)

    def slot_requirements(self, path, members, fields, links):
        requests = []
        for index, field in enumerate(fields):
            here = (*path, _step(field["wire_name"]))
            slot = field["slot"]
            if field["wire_name"] not in members:
                if slot["required"]: return ExpansionRejected(self.failure_at(links[index][0], here, ABSENT_VALUE, MISSING_REQUIRED))
                continue
            value = members[field["wire_name"]]
            if value is None:
                if not slot["nullable"]: return ExpansionRejected(self.failure_at(links[index][0], here, NULL_VALUE, NULL_NOT_ALLOWED))
                continue
            requests.append(ValueRequirement(slot["type_ref"], here, value, links[index]))
        return ExpansionRequirements(tuple(requests))

    def extra_field_requirements(self, path, spec, members, links):
        if sum_tag(spec["extras"]) != "Allow": return ()
        model = self.profile.get("tag")
        names = {field["wire_name"] for field in spec["fields"]}
        contract = payload(spec["extras"])["value"]
        link = links[len(spec["fields"])]
        requests = []
        for key, value in members_in_stored_order(members):
            if key in names or (model is not None and key == model["key"]): continue
            requests.extend(self.element_requirements(contract, (*path, _step(key)), value, link))
        return tuple(requests)

    def product_requirements(self, path, spec, members, links):
        slots = self.slot_requirements(path, members, spec["fields"], links)
        if isinstance(slots, ExpansionRejected): return slots
        return ExpansionRequirements((*slots.children, *self.extra_field_requirements(path, spec, members, links)))

    def expand_node(self, reference, path, value, node, key=None):
        links = () if node is None else self._links.get(ref_key(reference) if key is None else key, ())
        def reject(condition):
            return ExpansionRejected(self.failure_at(reference, path, PresentValue(value), condition))
        def rejected_at(failure):
            return ExpansionRejected(self.failure_at(reference, (*path, *(_step(item) for item in failure[0])), PresentValue(failure[2]), failure[1]))
        if node is None: return ExpansionUnresolved((self.obligation_at(reference, path, variant("UnresolvedType")),))
        shape = node["shape"]
        kind, spec = sum_tag(shape), payload(shape)
        is_object, is_decimal = isinstance(value, Mapping), isinstance(value, (float, DecimalLiteral, Decimal))
        if kind == "Boolean" and type(value) is bool:
            return reject(CONST_MISMATCH) if spec["const_value"] is not None and spec["const_value"] != value else ExpansionRequirements()
        if kind == "Integer":
            condition = integer_condition(self.profile, spec, value)
            return ExpansionRequirements() if condition is None else reject(condition)
        if kind == "Decimal" and is_decimal:
            condition = decimal_condition(spec, _decimal_text(value))
            return ExpansionRequirements() if condition is None else reject(condition)
        if kind == "String":
            condition = string_value_condition(self.profile, spec, value)
            return ExpansionRequirements() if condition is None else reject(condition)
        if kind == "Bytes":
            length = bytes_value_length(self.profile, value)
            if length is None: return reject(INVALID_BYTES)
            if (spec["minimum"] is None or integer(spec["minimum"]) <= length) and (spec["maximum"] is None or length <= integer(spec["maximum"])): return ExpansionRequirements()
            return reject(BYTES_LENGTH)
        if kind == "Product" and is_object:
            failure = object_member_failure(self.profile, value)
            if failure is not None: return rejected_at(failure)
            if classOf(self.profile, value)[0] != "Ordinary": return reject(wrong_value_kind("plain data object"))
            failure = self.extra_members_failure(spec, value)
            if failure is not None: return rejected_at(failure)
            return self.product_requirements(path, spec, value, links)
        if kind == "Array" and type(value) is list:
            minimum, maximum = spec["min_length"], spec["max_length"]
            if not ((minimum is None or integer(minimum) <= len(value)) and (maximum is None or len(value) <= integer(maximum))): return reject(ARRAY_LENGTH)
            return ExpansionRequirements(tuple(request for index, item in enumerate(value) for request in self.element_requirements(spec["item"], (*path, _step(index)), item, links[0])))
        if kind == "Alias": return ExpansionRequirements((ValueRequirement(spec["target"], path, value, links[0]),))
        if kind == "TaggedUnion":
            if is_object:
                failure = object_member_failure(self.profile, value)
                if failure is not None: return rejected_at(failure)
            branch = select_union_branch(self.profile, spec["branches"], value)
            if branch is None: return reject(NO_BRANCH_SELECTED)
            index = next(position for position, item in enumerate(spec["branches"]) if item is branch)
            return ExpansionRequirements((ValueRequirement(branch["target"], path, value, links[index]),))
        if kind == "Sealed" and is_object:
            failure = object_member_failure(self.profile, value)
            if failure is not None: return rejected_at(failure)
            classification, form = classOf(self.profile, value)
            if classification != "Sealed": return reject(wrong_value_kind("sealed object"))
            if form["tag"] != spec["tag"]: return reject(INVALID_DATA_MODEL)
            failure = sealed_fields_failure(self.profile, form, value)
            if failure is not None: return ExpansionRejected(self.failure_at(reference, (*path, _step(failure[0])), PresentValue(failure[2]), failure[1]))
            failure = sealed_extras_failure(self.profile, path, form, value)
            if failure is not None: return ExpansionRejected(self.failure_at(reference, failure[0], PresentValue(failure[2]), failure[1]))
            failure = sealed_refinement_failure(self.profile, value, spec["refinements"])
            if failure is not None: return ExpansionRejected(self.failure_at(reference, (*path, _step(failure[0])), PresentValue(failure[2]), failure[1]))
            return ExpansionRequirements()
        if kind == "Never": return reject(INVALID_DATA_MODEL)
        if kind == "Unknown" and sum_tag(spec) == "OrdinaryObject":
            if not is_object: return reject(wrong_value_kind("ordinary object"))
            failure = object_member_failure(self.profile, value)
            if failure is not None: return rejected_at(failure)
            if classOf(self.profile, value)[0] != "Ordinary": return reject(wrong_value_kind("ordinary object"))
        if kind == "Unknown":
            failure = data_value_failure(self.profile, path, value)
            return ExpansionRequirements() if failure is None else ExpansionRejected(self.failure_at(reference, failure[0], PresentValue(failure[2]), failure[1]))
        if kind == "Unit" and value is None: return ExpansionRequirements()
        if kind == "RawBody":
            return ExpansionRequirements() if bytes_value_length(self.profile, value) is not None else reject(INVALID_BYTES)
        if kind == "Opaque": return ExpansionUnresolved((self.obligation_at(reference, path, variant("OpaqueType", spec["type_name"])),))
        expected = {"Boolean": "boolean", "Decimal": "decimal", "Sealed": "sealed object", "Product": "object", "Array": "array", "Unit": "unit"}
        return reject(wrong_value_kind(expected[kind]))

    def expand_value(self, reference, path, value):
        reference, key = self._resolve(reference)
        return self.expand_node(reference, path, value, self.nodes.get(key), key)

    def check_value_fuel(self, fuel, seen, reference, path, value, expected):
        trail = None
        for item, at in reversed(seen):
            trail = (item, ref_key(item), len(at), trail)
        reference, key = self._resolve(reference)
        return _run_trampoline(self._check_value_steps(fuel, trail, reference, key, path, value, expected))

    def _check_value_steps(self, fuel, trail, reference, key, path, value, expected):
        if fuel == 0: return MembershipUnresolved((self.obligation_at(reference, path, variant("MembershipBound")),))
        depth = len(path)
        if _trail_holds(trail, key, depth):
            return MembershipRejected(self.failure_at(reference, path, PresentValue(value), REFERENCE_CYCLE, _trail_references(trail)))
        expansion = self.expand_node(reference, path, value, self.nodes.get(key), key)
        if isinstance(expansion, ExpansionRejected):
            failure = expansion.failure
            return MembershipRejected(ValueFailure(failure.type_ref, failure.value_path, failure.condition, failure.observed, _trail_references(trail)))
        if isinstance(expansion, ExpansionUnresolved): return MembershipUnresolved(expansion.obligations)
        wanted = None if expected is None else list(expected.children)
        taken = 0
        proofs = []
        here = (reference, key, depth, trail)
        for child in expansion.children:
            if wanted is not None and taken == len(wanted): return MembershipInvalidCertificate("missing membership children")
            head = None if wanted is None else wanted[taken]
            taken += 1
            child_reference, child_key = child.link
            checked = yield self._check_value_steps(fuel - 1, here, child_reference, child_key, child.value_path, child.value, head)
            if not isinstance(checked, MembershipAccepted): return checked
            proofs.append(checked.proof)
        if wanted is not None and taken < len(wanted): return MembershipInvalidCertificate("extra membership children")
        return MembershipAccepted(MemberProof(tuple(proofs)))

    def validate_value(self, reference, value, proof=None):
        reference, key = self._resolve(reference)
        return self._validate_resolved(reference, key, value, proof)

    def _validate_resolved(self, reference, key, value, proof):
        if self._blocked.get(key, True): return ValidationUnresolved(tuple(self._obligations([(reference, key)])))
        checked = _run_trampoline(self._check_value_steps((_json_size(value) + 1) * (len(self.nodes) + 1), None, reference, key, (), value, proof))
        if isinstance(checked, MembershipAccepted): return ValidatedValue(_validated_value_token, checked.proof)
        if isinstance(checked, MembershipRejected): return ValidationValueFailure(checked.failure)
        if isinstance(checked, MembershipUnresolved): return ValidationUnresolved(checked.obligations)
        return ValidationCertificateMismatch(checked.condition)

    def decode(self, reference, value):
        self.validate(reference, value)
        return value

    def _declared_default(self, link):
        reference, key = link
        for _ in range(len(self.nodes) + 1):
            node = self.nodes.get(key)
            if node is None:
                return None
            shape = node["shape"]
            kind, spec = sum_tag(shape), payload(shape)
            if kind == "Alias":
                reference, key = self._links[key][0]
            else:
                if kind in ("Boolean", "Integer", "String") and spec["default_value"] is not None:
                    value = integer(spec["default_value"]) if kind == "Integer" else spec["default_value"]
                    return reference, key, value
                return None
        return None

    def _default_draft(self, reference, value, path, fuel):
        reference, key = self._resolve(reference)
        return _run_trampoline(self._default_draft_steps(reference, key, value, path, fuel))

    def _default_draft_steps(self, reference, key, value, path, fuel):
        if fuel == 0:
            raise UnresolvedValueFailure([{
                "type_ref": reference,
                "origin": {"source": reference["source"], "pointer": reference["pointer"]},
                "value_path": tuple(path),
                "profile": self.profile["reference"],
                "reason": variant("MembershipBound"),
            }])
        node = self.nodes.get(key)
        if node is None:
            raise UnresolvedValueFailure([{
                "type_ref": reference,
                "origin": {"source": reference["source"], "pointer": reference["pointer"]},
                "value_path": tuple(path),
                "profile": self.profile["reference"],
                "reason": variant("UnresolvedType"),
            }])
        links = self._links[key]
        kind, spec = sum_tag(node["shape"]), payload(node["shape"])
        if kind == "Alias":
            return (yield self._default_draft_steps(*links[0], value, path, fuel - 1))
        if kind == "TaggedUnion" and isinstance(value, Mapping):
            tag_key = (self.profile.get("tag") or {}).get("key", "")
            tag = value.get(tag_key)
            index = next((position for position, branch in enumerate(spec["branches"]) if type(tag) is str and branch["wire_tag"] == tag), None)
            if index is not None:
                return (yield self._default_draft_steps(*links[index], value, path, fuel - 1))
        applications = []
        if kind == "Array" and type(value) is list:
            output = []
            for index, item in enumerate(value):
                after, evidence = yield self._default_draft_steps(*links[0], item, (*path, _step(index)), fuel - 1)
                output.append(after)
                applications.extend(evidence)
            return output, applications
        if kind == "Product" and isinstance(value, Mapping):
            output = []
            fields = {field["wire_name"]: position for position, field in enumerate(spec["fields"])}
            for member, item in value.items():
                if member in fields and item is not None:
                    item, evidence = yield self._default_draft_steps(*links[fields[member]], item, (*path, _step(member)), fuel - 1)
                    applications.extend(evidence)
                output.append((member, item))
            for position, field in enumerate(spec["fields"]):
                member = field["wire_name"]
                if member in value:
                    continue
                declared = self._declared_default(links[position])
                if declared is not None:
                    default_ref, default_key, item = declared
                    self._checked_resolved(default_ref, default_key, item)
                    applications.append(DefaultApplication((*path, _step(member)), default_ref, _default_origin(default_ref), item))
                    output.append((member, item))
            return JsonObject(output), applications
        return value, applications

    def check_default_applications(self, before, after, applications):
        def at(value, path):
            for step in path:
                if isinstance(step, (FieldStep, IndexStep)):
                    step = step.value
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
            reference = application.type_ref
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
                or application.origin != _default_origin(reference)
                or default != application.value):
                return False
        return True

    def materialize_defaults(self, reference, value):
        value = _value_json(value)
        reference, key = self._resolve(reference)
        after, applications = _run_trampoline(self._default_draft_steps(reference, key, value, (), (_json_size(value) + 1) * (len(self.nodes) + 1)))
        self._checked_resolved(reference, key, after)
        if not self.check_default_applications(value, after, applications):
            raise CertificateMismatchFailure("default source, absence, or result")
        result = object.__new__(DefaultedValue)
        object.__setattr__(result, "value", after)
        object.__setattr__(result, "applications", tuple(applications))
        return result

    def decode_with_defaults(self, reference, text):
        return self.materialize_defaults(reference, exact_from_json(decode_wire_json(text)))


    def encode(self, reference, value):
        self.validate(reference, value)
        return value


