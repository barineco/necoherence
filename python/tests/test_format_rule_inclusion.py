# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import json
from pathlib import Path

import pytest

from necoherence.signature_values import recognize_format, variant


def test_atproto_uri_format_accepts_did_authority_and_rejects_missing_scheme_or_whitespace():
    profile = json.loads(
        (Path(__file__).parents[2] / "presets/atproto-data-model/profile.json").read_text()
    )
    rule = next(binding["rule"] for binding in profile["format_bindings"] if binding["name"] == "uri")
    assert recognize_format(rule, "at://did:plc:ymdqgzoop3puhkbwrd7njbke/app.bsky.actor.profile/self")
    assert not recognize_format(rule, "https://example.com/has space")
    assert not recognize_format(rule, "example.com/path")


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
    assert recognize_format(rule,"a::b")
    assert not recognize_format(rule,"a:b")


def test_labels_recognition_rejects_an_empty_separator():
    rule=labels_with_separator("",lit("a"))
    assert not recognize_format(rule,"a")
    assert not recognize_format(rule,"")


def test_text_not_and_optional_sequence_match_lean_branches():
    assert recognize_format(variant("Text"),"anything")
    assert recognize_format(variant("Not",lit("x")),"y")
    assert not recognize_format(variant("Not",lit("x")),"x")
    rule=variant("Sequence",[variant("Optional",lit("a")),lit("b")])
    assert recognize_format(rule,"b") and recognize_format(rule,"ab")


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
    assert recognize_format(rule, text) is expected


@pytest.mark.parametrize("text,grandfathered,expected", [
    ("I-CUSTOM", ["i-custom"], True),
    ("i-custom", [], False),
    ("", [""], False),
    ("é", ["é"], False),
    ("k", ["K"], False),
])
def test_language_tag_recognition_uses_ascii_grandfathered_entries(text, grandfathered, expected):
    rule = variant("LanguageTag", fields={"grandfathered": grandfathered})
    assert recognize_format(rule, text) is expected


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
            assert recognize_format(rule, text) is (text in {"!", "a!", "😀!", "a😀!"})
    assert recognize_format(sequence([]), "")
    assert not recognize_format(sequence([]), "a")
    negated = sequence([lit("["), variant("Not", sequence([lit("a"), lit("😀")])), lit("]")])
    assert recognize_format(negated, "[]")
    assert recognize_format(negated, "[😀]")
    assert not recognize_format(negated, "[a😀]")


def test_sequence_labels_preserve_scalar_offsets_and_bounds():
    child = variant("Sequence", [variant("Optional", lit("a")), lit("😀")])
    inner = variant("Labels", fields={"separator": "🔹", "min_count": "2", "max_count": "2", "total_max": "4", "rule": child})
    rule = variant("Sequence", [lit("["), inner, lit("]")])
    for text, expected in [("[😀🔹a😀]", True), ("[a😀🔹😀]", True), ("[😀🔹b😀]", False), ("[😀🔹😀🔹😀]", False), ("[a😀🔹a😀]", False)]:
        assert recognize_format(rule, text) is expected
    assert recognize_format(bounded(15, rule), "[😀🔹a😀]")
    assert not recognize_format(bounded(14, rule), "[😀🔹a😀]")


def test_flat_sequence_with_600_parts_preserves_acceptance_and_rejection():
    parts = [lit("") for _ in range(600)]
    rule = variant("Sequence", parts)
    assert recognize_format(rule, "")
    assert not recognize_format(rule, "x")
    suffix = variant("Sequence", [*parts, lit("x")])
    assert recognize_format(suffix, "x")
    assert not recognize_format(suffix, "")
