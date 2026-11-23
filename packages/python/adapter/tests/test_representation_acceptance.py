# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from necoherence.signature_values import ValueContext, classOf, payload, select_union_branch, withMember, wrapDecode, wrapEncode
from necoherence.type_signatures import checkLibrary
from v4_samples import library
from necoherence.type_signatures import _graph


def test_runtime_functions_use_profile_declarations():
    checked = checkLibrary(library()); profile = checked.value["profile"]
    wrapped = wrapEncode(profile, "text", "x")
    assert wrapped == {"text":"x"}
    assert wrapDecode(profile, "text", wrapped) == "x"
    assert withMember("kind", "sealed", {"label":"x"}) == {"kind":"sealed","label":"x"}
    assert classOf(profile, {"kind":"sealed","label":"x"})[0] == "Sealed"
    graph = ValueContext(_graph({"profile": profile, "nodes": checked.value["nodes"], "definitions": []}))
    branches = payload(graph.shape("union"))["branches"]
    assert select_union_branch(graph.profile, branches, {"kind":"sealed","label":"x"}) is branches[0]
