# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence.signature_values import recognize_format, variant


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
