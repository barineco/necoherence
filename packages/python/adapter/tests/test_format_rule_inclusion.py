# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import json
from pathlib import Path

import pytest

from necoherence.signature_values import format_accepts_fast, variant


def test_atproto_uri_format_accepts_did_authority_and_rejects_missing_scheme_or_whitespace():
    profile = json.loads(
        (Path(__file__).parents[4] / "verification/presets/atproto-data-model/profile.json").read_text()
    )
    rule = next(binding["rule"] for binding in profile["format_bindings"] if binding["name"] == "uri")
    assert format_accepts_fast(None, rule, "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self")
    assert not format_accepts_fast(None, rule, "https://example.com/has space")
    assert not format_accepts_fast(None, rule, "example.com/path")


def lit(text): return variant("Literal",text)
def bounded(limit,rule): return variant("Bounded",fields={"unit":variant("Utf8Bytes"),"maximum":str(limit),"rule":rule})
def labels(minimum,maximum,rule): return variant("Labels",fields={"separator":".","min_count":str(minimum),"max_count":None if maximum is None else str(maximum),"total_max":None,"rule":rule})


def included(source,destination):
    if source==destination or destination==variant("Text"): return True
    return destination.get("tag")=="Choice" and any(included(source,item) for item in destination["value"])


@pytest.mark.parametrize("source,destination",[
    (lit("x"),lit("x")),
    (lit("x"),variant("Choice",[lit("x"),lit("y")])),
    (variant("Choice",[lit("x"),lit("y")]),variant("Choice",[variant("Choice",[lit("x"),lit("y")]),lit("z")])),
    (lit("x"),variant("Choice",[variant("Choice",[lit("x"),lit("y")])]))])
def test_format_inclusion_accepts_equal_rules_and_choice_members(source,destination):
    assert included(source,destination)


@pytest.mark.parametrize("source,destination",[
    (lit("x"),variant("Optional",lit("x"))),
    (bounded(5,lit("x")),bounded(10,lit("x"))),
    (variant("Sequence",[lit("x"),lit("y")]),variant("Sequence",[lit("x"),variant("Choice",[lit("y"),lit("z")])])),
    (labels(2,3,lit("x")),labels(1,4,lit("x"))),
    (variant("Choice",[lit("x"),lit("y")]),variant("Choice",[lit("x"),lit("y"),lit("z")]))])
def test_format_inclusion_is_structural_equality_or_choice_membership_only(source,destination):
    assert not included(source,destination)


def labels_with_separator(separator,rule): return variant("Labels",fields={"separator":separator,"min_count":"1","max_count":None,"total_max":None,"rule":rule})


def test_labels_recognition_splits_on_the_whole_separator():
    rule=labels_with_separator("::",variant("Choice",[lit("a"),lit("b")]))
    assert format_accepts_fast(None, rule,"a::b")
    assert not format_accepts_fast(None, rule,"a:b")


def test_labels_recognition_rejects_an_empty_separator():
    rule=labels_with_separator("",lit("a"))
    assert not format_accepts_fast(None, rule,"a")
    assert not format_accepts_fast(None, rule,"")


def test_text_not_and_optional_sequence_match_lean_branches():
    assert format_accepts_fast(None, variant("Text"),"anything")
    assert format_accepts_fast(None, variant("Not",lit("x")),"y")
    assert not format_accepts_fast(None, variant("Not",lit("x")),"x")
    rule=variant("Sequence",[variant("Optional",lit("a")),lit("b")])
    assert format_accepts_fast(None, rule,"b") and format_accepts_fast(None, rule,"ab")


@pytest.mark.parametrize("text,expected", [
    ("x-private", True),
    ("X-1-AbC", True),
    ("en", True),
    ("en-US", True),
    ("zh-Hant-TW", True),
    ("en-1901", True),
    ("en-GB-oed", True),
    ("I-KLINGON", True),
    ("sgn-be-fr", True),
    ("zh-cmn-Hans-CN", True),
    ("abc-def-ghi-jkl-Latn-419-1901-abcde-a-abc-b-def-x-1", True),
    ("abcd-Latn-US", True),
    ("abcdefgh", True),
    ("en-419", True),
    ("sl-rozaj-biske-1994", True),
    ("en-a-abc-b-def", True),
    ("en-0-ab-9-cd", True),
    ("en-x-a-12345678", True),
    ("en-a-12345678-x-a", True),
    ("en-a", False),
    ("en-a-abc-a-def", False),
    ("en-a-abc-A-def", False),
    ("en-1901-1901", False),
    ("sl-rozaj-ROZAJ", False),
    ("", False),
    ("é", False),
    ("en-１２３", False),
    ("x", False),
    ("x-", False),
    ("x-123456789", False),
    ("x-a-!", False),
    ("e", False),
    ("abcdefghi", False),
    ("12", False),
    ("en-", False),
    ("en--US", False),
    ("-en", False),
    ("en_US", False),
    ("en US", False),
    ("en-US\n", False),
    ("abc-def-ghi-jkl-mno", False),
    ("abcd-efg", False),
    ("en-US-Latn", False),
    ("en-abcd", True),
    ("en-1abc", True),
    ("en-123456789", False),
    ("en-a-b-cd", False),
    ("en-a-abc-x", False),
    ("en-x", False),
    ("en-x-a-", False),
    ("en-x-123456789", False),
])
def test_language_tag_recognition_matches_subtag_structure(text, expected):
    rule = variant("LanguageTag", fields={
        "grandfathered": ["en-GB-oed", "i-klingon", "sgn-BE-FR"],
    })
    assert format_accepts_fast(None, rule, text) is expected


@pytest.mark.parametrize("text,grandfathered,expected", [
    ("I-CUSTOM", ["i-custom"], True),
    ("i-custom", [], False),
    ("", [""], True),
    ("sgn-BE-FR", ["sgn-be-fr"], True),
    ("en-GB-oed", ["en-gb-oed"], True),
    ("é", ["é"], False),
    ("k", ["K"], False),
])
def test_language_tag_recognition_uses_ascii_grandfathered_entries(text, grandfathered, expected):
    rule = variant("LanguageTag", fields={"grandfathered": grandfathered})
    assert format_accepts_fast(None, rule, text) is expected


def test_sequence_grouping_preserves_concatenation_and_empty_parts():
    sequence = lambda parts: variant("Sequence", parts)
    first = variant("Choice", [lit(""), lit("a")])
    second = variant("Optional", lit("😀"))
    third = lit("!")
    rules = [
        sequence([first, second, third]),
        sequence([sequence([first, second]), third]),
        sequence([first, sequence([second, third])]),
        sequence([sequence([]), first, second, sequence([third]), sequence([])]),
    ]
    for text in ["", "!", "a!", "😀!", "a😀!", "aa!", "😀a!", "a😀", "x!"]:
        for rule in rules:
            assert format_accepts_fast(None, rule, text) is (text in {"!", "a!", "😀!", "a😀!"})
    assert format_accepts_fast(None, sequence([]), "")
    assert not format_accepts_fast(None, sequence([]), "a")
    negated = sequence([lit("["), variant("Not", sequence([lit("a"), lit("😀")])), lit("]")])
    assert format_accepts_fast(None, negated, "[]")
    assert format_accepts_fast(None, negated, "[😀]")
    assert not format_accepts_fast(None, negated, "[a😀]")


def test_sequence_labels_preserve_scalar_offsets_and_bounds():
    child = variant("Sequence", [variant("Optional", lit("a")), lit("😀")])
    inner = variant("Labels", fields={"separator": "🔹", "min_count": "2", "max_count": "2", "total_max": "4", "rule": child})
    rule = variant("Sequence", [lit("["), inner, lit("]")])
    for text, expected in [("[😀🔹a😀]", True), ("[a😀🔹😀]", True), ("[😀🔹b😀]", False), ("[😀🔹😀🔹😀]", False), ("[a😀🔹a😀]", False)]:
        assert format_accepts_fast(None, rule, text) is expected
    assert format_accepts_fast(None, bounded(15, rule), "[😀🔹a😀]")
    assert not format_accepts_fast(None, bounded(14, rule), "[😀🔹a😀]")


def test_flat_sequence_with_600_parts_preserves_acceptance_and_rejection():
    parts = [lit("") for _ in range(600)]
    rule = variant("Sequence", parts)
    assert format_accepts_fast(None, rule, "")
    assert not format_accepts_fast(None, rule, "x")
    suffix = variant("Sequence", [*parts, lit("x")])
    assert format_accepts_fast(None, suffix, "x")
    assert not format_accepts_fast(None, suffix, "")


def format_vectors():
    from necoherence.signature_values import format_accepts

    calendar = {"allow_second_60": False, "minimum_year": "2000", "maximum_year": "2001", "rejectUtcYearOutsideRange": True}
    seeds = [
        lit("a"),
        variant("Text"),
        variant("AsciiDfa", {"state_count": "1", "initial_state": "0", "accepting_states": ["0"], "transitions": []}),
        variant("Identifier", fields={"first_alphabet": "a", "rest_alphabet": "a", "exact_length": None, "min_length": "1", "max_length": "2", "forbidden": []}),
        variant("Timestamp", calendar),
        variant("AbsoluteUri", fields={"max_bytes": "16"}),
        variant("LanguageTag", fields={"grandfathered": []}),
    ]
    grow = lambda rule: [
        variant("Sequence", [rule, lit("#")]),
        variant("Optional", rule),
        variant("Labels", fields={"separator": ".", "min_count": "1", "max_count": "2", "total_max": "8", "rule": rule}),
        variant("Bounded", fields={"unit": variant("UnicodeScalars"), "maximum": "2", "rule": rule}),
        variant("Choice", [lit(""), rule]),
        variant("Not", rule),
    ]
    rules = seeds + [item for seed in seeds for item in grow(seed)] + [item for seed in seeds for first in grow(seed) for item in grow(first)]
    texts = ["", "a", "é", "#", "a#", "é#", "a.", "a.a"]
    return format_accepts, rules, texts


def test_fast_format_evaluation_agrees_with_the_direct_definition():
    format_accepts, rules, texts = format_vectors()
    for rule in rules:
        for text in texts:
            assert format_accepts_fast(None, rule, text) is format_accepts(None, rule, text), (rule, text)


def test_fast_format_evaluation_handles_long_complemented_choices():
    rule = variant("Not", variant("Choice", [lit(""), variant("Sequence", [variant("Text"), lit("#main")])]))
    assert format_accepts_fast(None, rule, "a" * 4000)


def test_labels_split_on_whole_separators_only():
    part = lit("a")
    labels = lambda minimum, rule=part: variant("Labels", fields={"separator": "::", "min_count": str(minimum), "max_count": None, "total_max": None, "rule": rule})
    assert not format_accepts_fast(None, labels(2), "a:a")
    assert format_accepts_fast(None, labels(2), "a::a")
    assert format_accepts_fast(None, labels(3), "a::a::a")
    assert format_accepts_fast(None, labels(1, lit("a:")), "a:")
    empty = variant("Labels", fields={"separator": "", "min_count": "2", "max_count": None, "total_max": None, "rule": part})
    assert not format_accepts_fast(None, empty, "a.a") and not format_accepts_fast(None, empty, "aa")


def test_sequence_vectors_from_the_lean_tests():
    from necoherence.signature_values import format_accepts

    sequence = lambda parts: variant("Sequence", parts)
    assert format_accepts(None, sequence([lit("a"), lit("b")]), "ab") and not format_accepts(None, sequence([lit("a"), lit("b")]), "a")
    assert format_accepts(None, sequence([]), "") and not format_accepts(None, sequence([]), "a")
    assert format_accepts(None, sequence([lit("a"), variant("Optional", lit("b"))]), "a")
    assert format_accepts(None, sequence([variant("Choice", [lit("a"), lit("a")]), lit("b")]), "ab")
    scalars = lambda maximum, rule: variant("Bounded", fields={"unit": variant("UnicodeScalars"), "maximum": str(maximum), "rule": rule})
    utf8 = variant("Bounded", fields={"unit": variant("Utf8Bytes"), "maximum": "2", "rule": lit("é")})
    assert format_accepts(None, sequence([utf8, scalars(1, lit("λ"))]), "éλ")
    assert format_accepts_fast(None, sequence([lit("é"), variant("Optional", lit("λ"))]), "éλ")


def test_timestamp_uri_and_identifier_leaves_follow_lean():
    calendar = {"allow_second_60": False, "minimum_year": "2000", "maximum_year": "2001", "rejectUtcYearOutsideRange": True}
    timestamp = variant("Timestamp", calendar)
    assert format_accepts_fast(None, timestamp, "2000-01-01T00:00:00Z")
    assert format_accepts_fast(None, timestamp, "2000-02-29T00:00:00.5+01:00")
    assert not format_accepts_fast(None, timestamp, "2000-01-01T00:30:00+01:00")
    assert not format_accepts_fast(None, timestamp, "2001-12-31T23:30:00-01:00")
    assert not format_accepts_fast(None, timestamp, "2001-02-29T00:00:00Z")
    assert not format_accepts_fast(None, timestamp, "2000-01-01T00:00:60Z")
    assert not format_accepts_fast(None, timestamp, "2000-01-01T00:00:00-00:00")
    assert not format_accepts_fast(None, timestamp, "1999-01-01T00:00:00Z")
    uri = variant("AbsoluteUri", fields={"max_bytes": None})
    assert format_accepts_fast(None, uri, "https://user@[::1]:80/a%20b?q#f")
    assert not format_accepts_fast(None, uri, "no-scheme")
    assert not format_accepts_fast(None, uri, "https://exa mple.com")
    assert not format_accepts_fast(None, uri, "https://x/%zz")
    identifier = variant("Identifier", fields={"first_alphabet": "ab", "rest_alphabet": "ab", "exact_length": "2", "min_length": "1", "max_length": None, "forbidden": ["aa"]})
    assert format_accepts_fast(None, identifier, "ab") and not format_accepts_fast(None, identifier, "aa") and not format_accepts_fast(None, identifier, "")
    assert not format_accepts_fast(None, identifier, "é")
