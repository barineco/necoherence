// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

import gleam/list
import gleam/option.{None, Some}
import necoherence/exact_json as json
import necoherence/semantic_composition as composition
import necoherence/semantic_types as types
import semantic_test_support as support

fn sampled(graph: types.SemanticGraph, name: String) -> List(json.JsonValue) {
  composition.samples(graph, support.reference(name), [], 100)
}

pub fn choice_format_samples_are_cut_at_the_remaining_fuel_test() {
  let profile =
    types.SemanticProfile(..support.profile(), format_bindings: [
      types.FormatBinding(
        "pick",
        support.profile_ref(),
        types.Choice([
          types.Literal("x"),
          types.Literal("y"),
          types.Literal("z"),
        ]),
      ),
    ])
  let graph =
    types.SemanticGraph(
      profile,
      [
        support.node(
          "picked",
          types.StringShape(types.StringSpec(
            Some(types.NamedFormat("pick")),
            [],
            None,
            None,
            None,
            [],
            None,
          )),
        ),
      ],
      [support.source()],
    )
  let assert [json.JsonValueStr("x"), json.JsonValueStr("y")] =
    sampled(graph, "picked")
}

pub fn product_take_follows_the_fuel_of_its_depth_test() {
  let graph =
    support.graph([
      support.node("flag", types.BooleanShape(types.BooleanSpec(None, None))),
      support.node(
        "mid",
        types.ProductShape(types.ProductSpec(
          [
            support.field("a", "flag", True, False),
            support.field("b", "flag", False, False),
          ],
          types.RejectExtras,
        )),
      ),
      support.node(
        "top",
        types.ProductShape(types.ProductSpec(
          [support.field("m", "mid", True, False)],
          types.RejectExtras,
        )),
      ),
    ])
  let assert 4 = list.length(sampled(graph, "mid"))
  let assert 3 = list.length(sampled(graph, "top"))
}

pub fn repeated_array_lengths_keep_duplicate_samples_test() {
  let graph =
    support.graph([
      support.node("flag", types.BooleanShape(types.BooleanSpec(None, None))),
      support.node(
        "list",
        types.ArrayShape(types.ArraySpec(
          types.ElementContract(support.reference("flag"), False),
          Some(1),
          Some(1),
        )),
      ),
    ])
  let assert 6 = list.length(sampled(graph, "list"))
}

pub fn sample_bound_obligation_matches_lean_representatives_test() {
  let long =
    support.graph([
      support.node(
        "long",
        types.StringShape(types.StringSpec(
          None,
          [],
          None,
          Some("aaaa"),
          None,
          [],
          None,
        )),
      ),
    ])
  let assert composition.SampleResult([], [composition.SampleBound]) =
    composition.sample_value_fuel(long, support.reference("long"), [], 2, 3)

  let fields =
    list.map(["a", "b", "c", "d"], fn(name) {
      support.field(name, "flag", True, False)
    })
  let combinations =
    support.graph([
      support.node("flag", types.BooleanShape(types.BooleanSpec(None, None))),
      support.node(
        "four-fields",
        types.ProductShape(types.ProductSpec(fields, types.RejectExtras)),
      ),
    ])
  let assert composition.SampleResult([], [composition.SampleBound]) =
    composition.sample_value_fuel(
      combinations,
      support.reference("four-fields"),
      [],
      3,
      3,
    )
  let assert composition.SampleResult(values, []) =
    composition.sample_value_fuel(
      combinations,
      support.reference("four-fields"),
      [],
      3,
      4,
    )
  let assert True = values != []
}
