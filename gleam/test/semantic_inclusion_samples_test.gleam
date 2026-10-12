// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None}
import necoherence/semantic_composition as composition
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
  ])
}

fn assert_valid_counterexample(
  graph: types.SemanticGraph,
  source: String,
  destination: String,
) {
  let assert composition.Incompatible(certificate) =
    composition.check_assignable(
      graph,
      contract(source),
      contract(destination),
      100,
    )
  let assert types.Present(value) = certificate.value
  let assert True =
    validation.accepts_slot(graph, contract(source), types.Present(value))
  let assert False =
    validation.accepts_slot(graph, contract(destination), types.Present(value))
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

pub fn inclusion_samples_are_accepted_by_the_source_test() {
  let graph = graph()
  composition.inclusion_samples(
    graph,
    support.reference("narrow"),
    support.reference("wide"),
    100,
  )
  |> list.each(fn(value) {
    let assert True =
      validation.accepts_value(graph, support.reference("narrow"), value)
  })
}
