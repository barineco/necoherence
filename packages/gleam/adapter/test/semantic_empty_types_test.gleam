// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/composition_plan
import necoherence/inclusion
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

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

fn forged_empty_types(name: String) {
  inclusion.verify_empty_types(validation.prepare(graph()), [
    support.reference(name),
  ])
}

pub fn never_type_is_not_accepted_as_empty_test() {
  let assert Error(composition_plan.ForgedEmptiness) =
    forged_empty_types("nothing")
}

pub fn integer_type_is_not_accepted_as_empty_test() {
  let assert Error(composition_plan.ForgedEmptiness) =
    forged_empty_types("integer-empty")
}

pub fn empty_types_hold_only_the_rows_the_checker_accepts_test() {
  let prepared = validation.prepare(graph())
  let declared = inclusion.empty_types(prepared)
  let assert True =
    declared == [support.reference("bytes-empty"), support.reference("loop")]
  let assert Ok(_) = inclusion.verify_empty_types(prepared, declared)
}

pub fn empty_source_types_are_accepted_by_the_checker_test() {
  let prepared = validation.prepare(graph())
  let declared = inclusion.empty_types(prepared)
  ["bytes-empty", "loop"]
  |> list.each(fn(source) {
    let assert True = list.contains(declared, support.reference(source))
    let assert Ok(_) = inclusion.verify_empty_types(prepared, declared)
  })
}
