# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence.signature_values import NO_BRANCH_SELECTED, ValueContext, ValueFailure, payload, select_union_branch
from necoherence.type_signatures import checkLibrary
from v4_samples import library
from necoherence.type_signatures import _graph


def test_internal_tag_selects_the_declared_branch():
    checked=checkLibrary(library()); graph=ValueContext(_graph({"profile": checked.value["profile"], "nodes": checked.value["nodes"], "definitions": []}))
    branches=payload(graph.shape("union"))["branches"]
    assert select_union_branch(graph.profile,branches,{"kind":"sealed","label":"x"}) is branches[0]
    assert select_union_branch(graph.profile,branches,{"kind":"other"}) is None
    with pytest.raises(ValueFailure) as caught: graph.validate("union",{"kind":"other"})
    assert caught.value.condition == NO_BRANCH_SELECTED
