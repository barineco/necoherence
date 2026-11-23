# SPDX-FileCopyrightText: 2026 barineco
# SPDX-License-Identifier: MIT

from typing import cast

from necoherence.semantic_composition import TypeRef, _type_ref_native
from necoherence.signature_values import ValueContext


def _integer_graph(domain: object) -> tuple[dict[str, object], list[object], TypeRef]:
    source = {
        "repository": "ncoh-type-signatures@1",
        "revision": "rev",
        "path": "path",
        "content_digest": "digest",
        "document_id": "doc",
        "declared_revision": None,
    }
    reference = {"source": source, "definition_name": "Count", "pointer": []}
    node = {
        "id": "Count",
        "reference": reference,
        "shape": {"tag": "Integer", "value": {"domain": domain, "minimum": None, "maximum": None}},
    }
    profile = {
        "reference": {"name": "profile"},
        "default_integer_domain": "number",
        "integer_domains": [{"name": "number", "range": {"tag": "Unbounded"}}],
    }
    graph: dict[str, object] = {"profile": profile, "nodes": [node]}
    return graph, [node], TypeRef(source, "Count", ())


def test_empty_integer_domain_name_is_looked_up_without_the_default() -> None:
    graph, nodes, reference = _integer_graph("")
    assert [cast(dict[str, object], item)["reason"] for item in tuple(ValueContext(graph).meaning_obligations([_type_ref_native(reference)]))] == [{"tag": "UnknownIntegerDomain", "value": ""}]


def test_absent_integer_domain_name_uses_the_default_domain() -> None:
    graph, nodes, reference = _integer_graph(None)
    assert [cast(dict[str, object], item)["reason"] for item in tuple(ValueContext(graph).meaning_obligations([_type_ref_native(reference)]))] == []
