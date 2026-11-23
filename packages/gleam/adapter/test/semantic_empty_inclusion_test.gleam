// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/composition_plan
import necoherence/inclusion
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn present(name: String) -> types.SlotContract {
  types.SlotContract(support.reference(name), True, False)
}

fn graph() -> types.SemanticGraph {
  support.graph([
    support.node("text", types.StringShape(support.string_spec(None))),
    support.node("nothing", types.Never),
    support.node(
      "bytes-small",
      types.BytesShape(types.LengthSpec(Some(1), Some(4))),
    ),
    support.node(
      "bytes-large",
      types.BytesShape(types.LengthSpec(Some(0), Some(8))),
    ),
    support.node(
      "bytes-empty",
      types.BytesShape(types.LengthSpec(Some(3), Some(1))),
    ),
    support.node(
      "integer-empty",
      types.IntegerShape(types.IntegerSpec(
        None,
        Some(5),
        Some(1),
        None,
        None,
        None,
      )),
    ),
    support.node(
      "loop",
      types.ProductShape(types.ProductSpec(
        [support.field("next", "loop", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "integer-holder",
      types.ProductShape(types.ProductSpec(
        [support.field("value", "integer-empty", True, False)],
        types.RejectExtras,
      )),
    ),
    support.node(
      "string-union",
      types.TaggedUnionShape(
        types.UnionSpec([
          types.UnionBranch(
            support.reference("text"),
            "string",
            types.Kind(types.StringKind),
            support.occurrence(),
          ),
        ]),
      ),
    ),
  ])
}

fn pair_entry(
  graph: types.SemanticGraph,
  source: String,
  destination: String,
  rule: composition_plan.InclusionRule,
) -> composition_plan.PairEntry {
  let assert Ok(source_node) =
    list.find(graph.nodes, fn(node) {
      node.reference == support.reference(source)
    })
  let assert Ok(destination_node) =
    list.find(graph.nodes, fn(node) {
      node.reference == support.reference(destination)
    })
  composition_plan.PairEntry(
    composition_plan.TypePair(present(source), present(destination), None),
    source_node.shape,
    destination_node.shape,
    rule,
    [],
  )
}

fn forged_empty_source(source: String, empty: List(String)) {
  let graph = graph()
  let certificate =
    composition_plan.InclusionCertificate(
      composition_plan.semantic_basis_of(graph),
      present(source),
      present("text"),
      list.map(empty, support.reference),
      [pair_entry(graph, source, "text", composition_plan.EmptySource)],
      0,
    )
  inclusion.verify_inclusion(
    validation.prepare(graph),
    present(source),
    present("text"),
    certificate,
  )
}

fn unknown_by_constraint(source: String, destination: String) {
  let assert inclusion.CompatibilityUnknown([
    composition_plan.TypeObligation(
      composition_plan.TypePair(source_contract, destination_contract, None),
      [],
      composition_plan.ConstraintImplication,
    ),
  ]) =
    inclusion.check_assignable(
      validation.prepare(graph()),
      present(source),
      present(destination),
      100,
    )
  let assert True = source_contract == present(source)
  let assert True = destination_contract == present(destination)
}

pub fn never_type_is_not_accepted_as_empty_test() {
  let assert Error(composition_plan.ForgedEmptiness) =
    forged_empty_source("nothing", ["nothing"])
}

pub fn integer_type_is_not_accepted_as_empty_test() {
  let assert Error(composition_plan.ForgedEmptiness) =
    forged_empty_source("integer-empty", ["integer-empty"])
}

pub fn bytes_pair_is_unknown_by_constraint_implication_test() {
  unknown_by_constraint("bytes-small", "bytes-large")
}

pub fn never_source_is_unknown_by_constraint_implication_test() {
  unknown_by_constraint("nothing", "text")
}

pub fn integer_range_without_values_is_unknown_by_constraint_implication_test() {
  unknown_by_constraint("integer-empty", "text")
  unknown_by_constraint("integer-holder", "text")
}

pub fn union_and_non_union_pairs_are_unknown_by_constraint_implication_test() {
  unknown_by_constraint("string-union", "text")
  unknown_by_constraint("text", "string-union")
}

pub fn empty_types_hold_only_the_rows_the_checker_accepts_test() {
  let graph = graph()
  let assert inclusion.Compatible(certificate) =
    inclusion.check_assignable(
      validation.prepare(graph),
      present("text"),
      present("text"),
      100,
    )
  let assert True =
    certificate.empty_types
    == [support.reference("bytes-empty"), support.reference("loop")]
  let assert Ok(_) =
    inclusion.verify_inclusion(
      validation.prepare(graph),
      present("text"),
      present("text"),
      certificate,
    )
}

pub fn empty_source_certificates_are_accepted_by_the_checker_test() {
  let graph = graph()
  ["bytes-empty", "loop"]
  |> list.each(fn(source) {
    let assert inclusion.Compatible(certificate) =
      inclusion.check_assignable(
        validation.prepare(graph),
        present(source),
        present("text"),
        100,
      )
    let assert [entry] = certificate.pairs
    let assert composition_plan.EmptySource = entry.rule
    let assert Ok(_) =
      inclusion.verify_inclusion(
        validation.prepare(graph),
        present(source),
        present("text"),
        certificate,
      )
  })
}
