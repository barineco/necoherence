# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

import pytest

from necoherence.signature_values import ValueFailure, selectBranch
from necoherence.type_signatures import checkLibrary
from v4_samples import library


def test_internal_tag_selects_the_declared_branch():
    checked=checkLibrary(library()); graph={"profile":checked.value["profile"],"nodes":checked.value["nodes"]}
    assert selectBranch(graph,"union",{"kind":"sealed","label":"x"})==0
    with pytest.raises(ValueFailure) as caught: selectBranch(graph,"union",{"kind":"other"})
    assert caught.value.condition=="NoBranchSelected"
