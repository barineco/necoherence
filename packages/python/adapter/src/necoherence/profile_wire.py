# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

"""Typed wire checks for the semantic profile, mirroring the Lean SignatureProfileWire instances."""
from __future__ import annotations

from typing import Any

from .wire_schema import UNIT, boolean, direct, int_text, listed, nat_text, optional, record, record_case, string, tuple_case, units, variant

PROFILE_REF = record(("identity", string), ("revision", string), ("content_digest", string))
SOURCE_IDENTITY = record(("repository", string), ("revision", string), ("path", string), ("content_digest", string))
ORIGIN = record(("source", SOURCE_IDENTITY), ("locator", listed(string)))

INTEGER_DOMAIN = variant({
    "Unbounded": UNIT,
    "Inclusive": record_case(record(("minimum", int_text), ("maximum", int_text))),
})
INTEGER_FORM = variant(units("Number", "IntegralDecimal", "DecimalString"))
INTEGER_DOMAIN_BINDING = record(
    ("name", string), ("reference", PROFILE_REF), ("range", INTEGER_DOMAIN), ("forms", listed(INTEGER_FORM)),
)
NUMBER_MODEL = record(("decimals", boolean))
BYTES_ALPHABET = variant(units("Standard", "UrlSafe", "Either"))
STRING_LENGTH_UNIT = variant(units("Utf8Bytes", "UnicodeScalars", "Graphemes"))

CODEPOINT_RANGE = record(("first", nat_text), ("last", nat_text))
GRAPHEME_PROPERTY = variant(units(
    "Other", "Cr", "Lf", "Control", "Extend", "Zwj", "RegionalIndicator",
    "Prepend", "SpacingMark", "L", "V", "T", "Lv", "Lvt",
))
GRAPHEME_RANGE = record(("first", nat_text), ("last", nat_text), ("property", GRAPHEME_PROPERTY))
INDIC_PROPERTY = variant(units("Other", "Consonant", "Extend", "Linker"))
INDIC_RANGE = record(("first", nat_text), ("last", nat_text), ("property", INDIC_PROPERTY))
GRAPHEME_COMPONENT = record(
    ("unicode_version", string), ("uax29_revision", string), ("cluster_profile", string),
)
GRAPHEME_SOURCE = record(("role", string), ("origin", ORIGIN))
GRAPHEME_RULES = record(
    ("reference", PROFILE_REF), ("component", GRAPHEME_COMPONENT), ("table_sha256", string),
    ("sources", listed(GRAPHEME_SOURCE)), ("properties", listed(GRAPHEME_RANGE)),
    ("extended_pictographic", listed(CODEPOINT_RANGE)), ("indic_conjunct", listed(INDIC_RANGE)),
)

BYTES_POLICY = record(
    ("reference", PROFILE_REF), ("padding_optional", boolean), ("alphabet", BYTES_ALPHABET),
    ("strict_pad_bits", boolean), ("wrapper", optional(string)),
)

CALENDAR_RULE = record(
    ("allow_second_60", boolean), ("minimum_year", nat_text), ("maximum_year", nat_text),
    ("rejectUtcYearOutsideRange", boolean),
)
DFA_TRANSITION = record(
    ("from_state", nat_text), ("first", nat_text), ("last", nat_text), ("to_state", nat_text),
)
DFA_SPEC = record(
    ("state_count", nat_text), ("initial_state", nat_text), ("accepting_states", listed(nat_text)),
    ("transitions", listed(DFA_TRANSITION)),
)


def format_rule(value: Any, path: str) -> None:
    _FORMAT_RULE(value, path)


_FORMAT_RULE = variant({
    "Literal": tuple_case(string),
    "Sequence": tuple_case(listed(format_rule)),
    "Optional": tuple_case(format_rule),
    "Labels": record_case(record(
        ("separator", string), ("min_count", nat_text), ("max_count", optional(nat_text)),
        ("total_max", optional(nat_text)), ("rule", direct(format_rule)),
    )),
    "Bounded": record_case(record(
        ("unit", STRING_LENGTH_UNIT), ("maximum", nat_text), ("rule", direct(format_rule)),
    )),
    "AsciiDfa": tuple_case(DFA_SPEC),
    "Timestamp": tuple_case(CALENDAR_RULE),
    "Choice": tuple_case(listed(format_rule)),
    "Identifier": record_case(record(
        ("first_alphabet", string), ("rest_alphabet", string), ("exact_length", optional(nat_text)),
        ("min_length", nat_text), ("max_length", optional(nat_text)), ("forbidden", listed(string)),
    )),
    "AbsoluteUri": record_case(record(("max_bytes", optional(nat_text)))),
    "LanguageTag": record_case(record(("grandfathered", listed(string)))),
    "Text": UNIT,
    "Not": tuple_case(format_rule),
})

FORMAT_USE = variant({"Named": tuple_case(string), "Inline": tuple_case(format_rule)})
FORMAT_BINDING = record(("name", string), ("reference", PROFILE_REF), ("rule", format_rule))

LENGTH_BOUND = record(
    ("unit", STRING_LENGTH_UNIT), ("minimum", optional(nat_text)), ("maximum", optional(nat_text)),
)
INTEGER_SPEC = record(
    ("domain", optional(string)), ("minimum", optional(int_text)), ("maximum", optional(int_text)),
    ("const_value", optional(int_text)), ("enum_values", optional(listed(int_text))),
    ("default_value", optional(int_text)),
)
STRING_SPEC = record(
    ("format", optional(FORMAT_USE)), ("lengths", listed(LENGTH_BOUND)), ("wrapper", optional(string)),
    ("const_value", optional(string)), ("enum_values", optional(listed(string))),
    ("examples", listed(string)), ("default_value", optional(string)),
)

WRAPPER_PAYLOAD = variant({"Bytes": UNIT, "Text": tuple_case(optional(string))})
WRAPPER = record(("name", string), ("key", string), ("payload", WRAPPER_PAYLOAD))

SEALED_LEAF = variant({"String": tuple_case(STRING_SPEC), "Integer": tuple_case(INTEGER_SPEC)})
SEALED_FIELD = record(("key", string), ("required", boolean), ("leaf", SEALED_LEAF))
SEALED_EXTRAS = variant(units("Reject", "Any"))
SEALED_FORM = record(("tag", string), ("fields", listed(SEALED_FIELD)), ("extras", SEALED_EXTRAS))
SEALED_REFINEMENT = record(("key", string), ("leaf", SEALED_LEAF))
TAG_MODEL = record(("key", string), ("format", optional(string)), ("sealed", listed(SEALED_FORM)))

VALUE_PROFILE = record(
    ("reference", PROFILE_REF), ("source_refs", listed(SOURCE_IDENTITY)),
    ("integer_domains", listed(INTEGER_DOMAIN_BINDING)), ("default_integer_domain", string),
    ("numbers", NUMBER_MODEL), ("grapheme_rules", optional(GRAPHEME_RULES)),
    ("format_bindings", listed(FORMAT_BINDING)), ("bytes_policy", optional(BYTES_POLICY)),
    ("wrappers", listed(WRAPPER)), ("tag", optional(TAG_MODEL)),
)
