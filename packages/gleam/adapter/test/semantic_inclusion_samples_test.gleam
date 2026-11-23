// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/option.{None, Some}
import necoherence/composition_plan
import necoherence/exact_json as json
import necoherence/inclusion
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn contract(name: String) -> types.SlotContract {
  types.SlotContract(support.reference(name), True, False)
}

fn graph() -> types.SemanticGraph {
  let any = support.node("any", types.UnknownShape(types.AnyValue))
  let narrow =
    support.node(
      "narrow",
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(support.reference("any"), False),
        ),
      )),
    )
  let wide =
    support.node(
      "wide",
      types.ProductShape(types.ProductSpec([], types.RejectExtras)),
    )
  support.graph([
    any,
    narrow,
    wide,
    support.node(
      "narrow-holder",
      types.ProductShape(types.ProductSpec(
        [support.field("inner", "narrow", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "wide-holder",
      types.ProductShape(types.ProductSpec(
        [support.field("inner", "wide", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "narrow-list",
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(support.reference("narrow"), False),
        None,
        None,
      )),
    ),
    support.node(
      "wide-list",
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(support.reference("wide"), False),
        None,
        None,
      )),
    ),
    support.node("string", types.StringShape(support.string_spec(None))),
    support.node(
      "any-item-list",
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(support.reference("any"), False),
        None,
        None,
      )),
    ),
    support.node(
      "string-item-list",
      types.ArrayShape(types.ArraySpec(
        types.ElementContract(support.reference("string"), False),
        None,
        None,
      )),
    ),
    support.node(
      "any-extra-product",
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(support.reference("any"), False),
        ),
      )),
    ),
    support.node(
      "string-extra-product",
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          None,
          types.ElementContract(support.reference("string"), False),
        ),
      )),
    ),
    support.node(
      "zero-to-nine",
      types.IntegerShape(types.IntegerSpec(
        None,
        Some(0),
        Some(9),
        None,
        None,
        None,
      )),
    ),
    support.node(
      "zero-to-ten",
      types.IntegerShape(types.IntegerSpec(
        None,
        Some(0),
        Some(10),
        None,
        None,
        None,
      )),
    ),
    support.node(
      "extras-value-source",
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          Some(types.InlineFormat(types.Literal("x"))),
          types.ElementContract(support.reference("zero-to-nine"), False),
        ),
      )),
    ),
    support.node(
      "extras-value-destination",
      types.ProductShape(types.ProductSpec(
        [],
        types.AllowExtras(
          Some(types.InlineFormat(types.Literal("x"))),
          types.ElementContract(support.reference("zero-to-ten"), False),
        ),
      )),
    ),
  ])
}

fn assert_valid_counterexample(
  graph: types.SemanticGraph,
  source: String,
  destination: String,
) {
  let assert inclusion.Incompatible(certificate) =
    inclusion.check_assignable(
      validation.prepare(graph),
      contract(source),
      contract(destination),
      100,
    )
  let assert types.Present(value) = certificate.value
  let assert True =
    validation.accepts_slot(
      validation.prepare(graph),
      contract(source),
      types.Present(value),
    )
    == types.AcceptedValue
  let assert False =
    validation.accepts_slot(
      validation.prepare(graph),
      contract(destination),
      types.Present(value),
    )
    == types.AcceptedValue
}

pub fn top_level_product_inclusion_returns_valid_counterexample_test() {
  let graph = graph()
  assert_valid_counterexample(graph, "narrow", "wide")
}

pub fn nested_product_and_array_inclusion_return_valid_counterexamples_test() {
  let graph = graph()
  assert_valid_counterexample(graph, "narrow-holder", "wide-holder")
  assert_valid_counterexample(graph, "narrow-list", "wide-list")
}

pub fn element_inclusion_uses_type_null_acceptance_test() {
  let graph = graph()
  assert_valid_counterexample(graph, "any-item-list", "string-item-list")
  assert_valid_counterexample(
    graph,
    "any-extra-product",
    "string-extra-product",
  )
}

pub fn reverse_extras_value_inclusion_returns_boundary_counterexample_test() {
  let graph = graph()
  let assert inclusion.Incompatible(certificate) =
    inclusion.check_assignable(
      validation.prepare(graph),
      contract("extras-value-destination"),
      contract("extras-value-source"),
      100,
    )
  let assert types.Present(json.JsonValueObj([#("x", json.JsonValueNum(10))])) =
    certificate.value
}

pub fn counterexample_verification_matches_the_given_source_and_destination_test() {
  let graph = graph()
  let assert inclusion.Incompatible(certificate) =
    inclusion.check_assignable(
      validation.prepare(graph),
      contract("narrow"),
      contract("wide"),
      100,
    )
  let assert Ok(_) =
    inclusion.verify_counterexample(
      validation.prepare(graph),
      contract("narrow"),
      contract("wide"),
      certificate,
    )
  let assert Error(composition_plan.InclusionBasisMismatch) =
    inclusion.verify_counterexample(
      validation.prepare(graph),
      contract("wide"),
      contract("wide"),
      certificate,
    )
  let assert Error(composition_plan.InclusionBasisMismatch) =
    inclusion.verify_counterexample(
      validation.prepare(graph),
      contract("narrow"),
      contract("narrow"),
      certificate,
    )
}
