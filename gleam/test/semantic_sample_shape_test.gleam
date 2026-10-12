// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_types as types
import necoherence/semantic_validation as validation
import semantic_test_support as support

fn sampled(graph: types.SemanticGraph, name: String) -> List(json.JsonValue) {
  composition.samples(graph, support.reference(name), [], 100)
}

pub fn scalar_samples_follow_declared_constraints_test() {
  let graph =
    support.graph([
      support.node(
        "free-boolean",
        types.BooleanShape(types.BooleanSpec(None, None)),
      ),
      support.node(
        "fixed-boolean",
        types.BooleanShape(types.BooleanSpec(Some(True), None)),
      ),
      support.node(
        "integer",
        types.IntegerShape(types.IntegerSpec(
          None,
          Some(-5),
          Some(5),
          None,
          None,
          None,
        )),
      ),
      support.node("decimal", types.DecimalShape(types.DecimalSpec(None, None))),
    ])
  let assert [json.JsonValueBool(False), json.JsonValueBool(True)] =
    sampled(graph, "free-boolean")
  let assert [json.JsonValueBool(True)] = sampled(graph, "fixed-boolean")
  let integers = sampled(graph, "integer")
  let assert True = list.contains(integers, json.JsonValueNum(-5))
  let assert True = list.contains(integers, json.JsonValueNum(5))
  let assert [json.JsonValueDec("0"), json.JsonValueDec("1")] =
    sampled(graph, "decimal")
}

pub fn wrapper_sealed_and_never_samples_follow_profile_test() {
  let graph =
    support.graph([
      support.node("bytes", types.BytesShape(types.LengthSpec(None, None))),
      support.node("sealed", types.SealedShape("sealed", [])),
      support.node("never", types.Never),
    ])
  let bytes = sampled(graph, "bytes")
  let assert True =
    list.contains(bytes, json.JsonValueObj([#("bytes", json.JsonValueStr(""))]))
  let sealed = sampled(graph, "sealed")
  let assert [json.JsonValueObj([#("tag", json.JsonValueStr("sealed"))])] =
    sealed
  let assert [] = sampled(graph, "never")
}

pub fn array_and_product_samples_enumerate_declared_choices_test() {
  let graph =
    support.graph([
      support.node("flag", types.BooleanShape(types.BooleanSpec(None, None))),
      support.node(
        "list",
        types.ArrayShape(types.ArraySpec(
          types.ElementContract(support.reference("flag"), False),
          None,
          Some(1),
        )),
      ),
      support.node(
        "pair",
        types.ProductShape(types.ProductSpec(
          [
            support.field("a", "flag", True, False),
            support.field("o", "flag", False, False),
          ],
          types.RejectExtras,
        )),
      ),
    ])
  let arrays = sampled(graph, "list")
  let assert True = list.contains(arrays, json.JsonValueArr([]))
  let assert True =
    list.contains(arrays, json.JsonValueArr([json.JsonValueBool(False)]))
  let products = sampled(graph, "pair")
  let assert 4 = list.length(products)
  list.each(products, fn(value) {
    let assert True =
      validation.accepts_value(graph, support.reference("pair"), value)
  })
}

pub fn union_selector_samples_are_members_test() {
  let graph =
    support.graph([
      support.node(
        "product",
        types.ProductShape(types.ProductSpec([], types.RejectExtras)),
      ),
      support.node("text", types.StringShape(support.string_spec(None))),
      support.node("flag", types.BooleanShape(types.BooleanSpec(None, None))),
      support.node(
        "union",
        types.TaggedUnionShape(
          types.UnionSpec([
            types.UnionBranch(
              support.reference("product"),
              "internal",
              types.InternalTag,
              support.occurrence(),
            ),
            types.UnionBranch(
              support.reference("product"),
              "shape",
              types.MemberShape([#("shape", types.FormatMember("text"))]),
              support.occurrence(),
            ),
            types.UnionBranch(
              support.reference("text"),
              "string",
              types.Kind(types.StringKind),
              support.occurrence(),
            ),
            types.UnionBranch(
              support.reference("flag"),
              "otherwise",
              types.Otherwise,
              support.occurrence(),
            ),
          ]),
        ),
      ),
    ])
  let values = sampled(graph, "union")
  let assert True = values != []
  list.each(values, fn(value) {
    let assert True =
      validation.accepts_value(graph, support.reference("union"), value)
  })
}
